defmodule TypeDB.Stub do
  @moduledoc """
  A minimal HTTP server that speaks the TypeDB HTTP API v1.

  Used to exercise the whole driver — sign-in, token renewal, retries, encoding,
  answer decoding, error mapping — without a TypeDB server and without any
  dependency. Erlang's `packet: :http_bin` socket mode does the HTTP parsing, so
  this is a real HTTP/1.1 server with keep-alive, not a mock.

  Two modes:

    * default: an in-memory emulation of the API (databases, transactions,
      queries) driven by `TypeDB.Stub.Router`
    * `handler: fun` : full control, for testing failure paths

        TypeDB.Stub.start_link(handler: fn _method, _path, _headers, _body ->
          {503, [], ""}
        end)
  """

  use GenServer

  @type request :: %{method: String.t(), path: String.t(), headers: map(), body: binary()}
  @type response :: {status :: pos_integer(), headers :: [{String.t(), String.t()}], body :: binary()}
  @type handler :: (String.t(), String.t(), map(), binary() -> response())

  defmodule State do
    @moduledoc false
    defstruct [:listen_socket, :port, :handler, :owner, requests: [], router: nil]
  end

  @doc """
  Starts a stub server on an ephemeral port.

  Options:

    * `:handler` — a 4-arity function replacing the built-in router
    * `:username` / `:password` — accepted credentials. Defaults to
      `"admin"` / `"password"`
    * `:token_uses` — how many requests each issued token survives, to exercise
      token renewal. Defaults to `:infinity`
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, {opts, self()})
  end

  @doc "Returns the port the stub is listening on."
  @spec port(pid()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @doc "Returns the base URL of the stub."
  @spec url(pid()) :: String.t()
  def url(server), do: "http://127.0.0.1:#{port(server)}"

  @doc "Returns every request the stub has received, oldest first."
  @spec requests(pid()) :: [request()]
  def requests(server), do: GenServer.call(server, :requests)

  @doc "Stops the stub."
  @spec stop(pid()) :: :ok
  def stop(server), do: GenServer.stop(server)

  @doc false
  def record(server, request), do: GenServer.cast(server, {:record, request})

  @impl true
  def init({opts, owner}) do
    listen_opts = [
      :binary,
      packet: :http_bin,
      active: false,
      reuseaddr: true,
      ip: {127, 0, 0, 1},
      backlog: 128
    ]

    {:ok, listen_socket} = :gen_tcp.listen(0, listen_opts)
    {:ok, port} = :inet.port(listen_socket)

    handler = Keyword.get(opts, :handler) || TypeDB.Stub.Router.build(opts)

    state = %State{listen_socket: listen_socket, port: port, handler: handler, owner: owner}
    send(self(), :accept)
    {:ok, state}
  end

  @impl true
  def handle_info(:accept, %State{} = state) do
    server = self()
    listen_socket = state.listen_socket
    handler = state.handler

    spawn_link(fn -> accept_loop(server, listen_socket, handler) end)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}
  def handle_call(:requests, _from, state), do: {:reply, Enum.reverse(state.requests), state}

  @impl true
  def handle_cast({:record, request}, state) do
    {:noreply, %{state | requests: [request | state.requests]}}
  end

  @impl true
  def terminate(_reason, %State{listen_socket: socket}) do
    :gen_tcp.close(socket)
    :ok
  end

  defp accept_loop(server, listen_socket, handler) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        spawn_link(fn -> serve(server, socket, handler) end)
        accept_loop(server, listen_socket, handler)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp serve(server, socket, handler) do
    case read_request(socket) do
      {:ok, method, path, headers, body} ->
        record(server, %{method: method, path: path, headers: headers, body: body})

        {status, response_headers, response_body} =
          try do
            handler.(method, path, headers, body)
          rescue
            error -> {500, [], "stub handler crashed: " <> Exception.message(error)}
          end

        _ = :gen_tcp.send(socket, encode_response(status, response_headers, response_body))
        # Reset to header mode and keep the connection alive for the next request.
        _ = :inet.setopts(socket, packet: :http_bin)
        serve(server, socket, handler)

      {:error, _reason} ->
        :gen_tcp.close(socket)
    end
  end

  defp read_request(socket) do
    case :gen_tcp.recv(socket, 0, 30_000) do
      {:ok, {:http_request, method, {:abs_path, path}, _version}} ->
        with {:ok, headers} <- read_headers(socket, %{}),
             {:ok, body} <- read_body(socket, headers) do
          {:ok, to_string(method), path, headers, body}
        end

      {:ok, other} ->
        {:error, {:unexpected, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_headers(socket, acc) do
    case :gen_tcp.recv(socket, 0, 30_000) do
      {:ok, {:http_header, _, name, _, value}} ->
        key = name |> to_string() |> String.downcase()
        read_headers(socket, Map.put(acc, key, value))

      {:ok, :http_eoh} ->
        {:ok, acc}

      {:ok, other} ->
        {:error, {:unexpected_header, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_body(socket, headers) do
    case Integer.parse(Map.get(headers, "content-length", "0")) do
      {0, _} ->
        {:ok, ""}

      {length, _} ->
        _ = :inet.setopts(socket, packet: :raw)
        :gen_tcp.recv(socket, length, 30_000)

      :error ->
        {:ok, ""}
    end
  end

  defp encode_response(status, headers, body) do
    body = IO.iodata_to_binary(body)

    base = [
      {"content-length", Integer.to_string(byte_size(body))},
      {"connection", "keep-alive"}
    ]

    headers =
      if List.keyfind(headers, "content-type", 0) || body == "" do
        headers
      else
        [{"content-type", "application/json"} | headers]
      end

    header_lines = Enum.map_join(headers ++ base, "", fn {name, value} -> "#{name}: #{value}\r\n" end)

    "HTTP/1.1 #{status} #{reason_phrase(status)}\r\n" <> header_lines <> "\r\n" <> body
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(204), do: "No Content"
  defp reason_phrase(400), do: "Bad Request"
  defp reason_phrase(401), do: "Unauthorized"
  defp reason_phrase(403), do: "Forbidden"
  defp reason_phrase(404), do: "Not Found"
  defp reason_phrase(408), do: "Request Timeout"
  defp reason_phrase(500), do: "Internal Server Error"
  defp reason_phrase(503), do: "Service Unavailable"
  defp reason_phrase(_), do: "Unknown"
end
