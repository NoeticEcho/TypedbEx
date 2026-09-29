defmodule TypeDB.SocketFault do
  @moduledoc """
  A TCP listener that speaks just enough HTTP to be believed, then misbehaves.

  `TypeDB.FaultAdapter` fakes a broken adapter, which is the right tool for
  "whatever the adapter does, the caller gets a `TypeDB.Error`". It cannot ask
  the other half of the question: what the three *real* adapters do when the
  socket under them misbehaves, and whether they agree. A connection dropped
  halfway through a body, a server that accepts and then says nothing, bytes
  that are not HTTP at all — none of those can be expressed as a return value,
  because they are not one.

  So: a real listener, one named fault each.

    * `:closed_before_response` — read the request, close without answering
    * `:closed_mid_body` — a complete set of headers promising 500 bytes, then
      20 bytes and a close
    * `:closed_mid_headers` — half a status line, then a close
    * `:garbage` — bytes that are not HTTP
    * `:never_answers` — accept, read, hold the socket open and say nothing,
      which is what a stall past the timeout looks like from the client
    * `:accept_and_reset` — an RST rather than a FIN, via `linger: {true, 0}`

  Every fault answers the same way on every connection, so a retry meets the
  same wall the first attempt did. `requests/1` says how many were made, which
  is how the retry policy is checked against a real socket.
  """

  use GenServer

  @faults [
    :closed_before_response,
    :closed_mid_body,
    :closed_mid_headers,
    :garbage,
    :never_answers,
    :accept_and_reset
  ]

  @doc "Every socket-level fault this listener knows how to produce."
  @spec faults() :: [atom()]
  def faults, do: @faults

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, {opts, self()})

  @spec url(pid()) :: String.t()
  def url(server), do: "http://127.0.0.1:#{GenServer.call(server, :port)}"

  @doc "How many requests have been read off a socket since the listener started."
  @spec requests(pid()) :: non_neg_integer()
  def requests(server), do: GenServer.call(server, :requests)

  @spec stop(pid()) :: :ok
  def stop(server), do: GenServer.stop(server)

  @impl true
  def init({opts, owner}) do
    fault = Keyword.fetch!(opts, :fault)
    true = fault in @faults

    listen_opts = [
      :binary,
      packet: :raw,
      active: false,
      reuseaddr: true,
      ip: {127, 0, 0, 1},
      backlog: 128
    ]

    {:ok, socket} = :gen_tcp.listen(0, listen_opts)
    {:ok, port} = :inet.port(socket)

    Process.flag(:trap_exit, true)
    Process.monitor(owner)

    state = %{socket: socket, port: port, fault: fault, requests: 0, handlers: []}
    {:ok, state, {:continue, :accept}}
  end

  @impl true
  def handle_continue(:accept, state) do
    parent = self()
    spawn_link(fn -> accept_loop(state.socket, state.fault, parent) end)
    {:noreply, state}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}
  def handle_call(:requests, _from, state), do: {:reply, state.requests, state}

  @impl true
  def handle_info(:request_read, state), do: {:noreply, %{state | requests: state.requests + 1}}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:stop, :normal, state}
  # The acceptor exits with the listening socket when this process stops; while
  # it is alive, a handler that lost its socket is not this listener's problem.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: :gen_tcp.close(state.socket)

  defp accept_loop(listen_socket, fault, parent) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        {:ok, handler} = Task.start(fn -> handle(socket, fault, parent) end)
        :ok = :gen_tcp.controlling_process(socket, handler)
        send(handler, :take_over)
        accept_loop(listen_socket, fault, parent)

      {:error, :closed} ->
        :ok
    end
  end

  defp handle(socket, fault, parent) do
    receive do
      :take_over -> :ok
    after
      5_000 -> :ok
    end

    # `accept_and_reset` never reads: the point is an RST before the client has
    # been answered at all, and reading first would sometimes let the response
    # race ahead of it.
    if fault != :accept_and_reset do
      read_request(socket)
      send(parent, :request_read)
    end

    respond(socket, fault)
  end

  # Enough of HTTP/1.1 to know the request is over: headers end at a blank line,
  # and every request the driver sends is either bodyless or carries a
  # content-length.
  defp read_request(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        acc = acc <> data

        case String.split(acc, "\r\n\r\n", parts: 2) do
          [headers, body] -> read_body(socket, headers, body)
          [_partial] -> read_request(socket, acc)
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp read_body(socket, headers, body) do
    case content_length(headers) do
      0 -> :ok
      length when byte_size(body) >= length -> :ok
      length -> read_body(socket, headers, body <> recv(socket, length - byte_size(body)))
    end
  end

  defp recv(socket, bytes) do
    case :gen_tcp.recv(socket, bytes, 5_000) do
      {:ok, data} -> data
      {:error, _reason} -> ""
    end
  end

  defp content_length(headers) do
    headers
    |> String.split("\r\n")
    |> Enum.find_value(0, &content_length_header/1)
  end

  defp content_length_header(line) do
    case String.split(line, ":", parts: 2) do
      [name, value] -> content_length_value(String.downcase(String.trim(name)), value)
      _other -> nil
    end
  end

  defp content_length_value("content-length", value), do: value |> String.trim() |> String.to_integer()
  defp content_length_value(_name, _value), do: nil

  defp respond(socket, :closed_before_response), do: :gen_tcp.close(socket)

  defp respond(socket, :closed_mid_body) do
    :gen_tcp.send(socket, """
    HTTP/1.1 200 OK\r
    content-type: application/json\r
    content-length: 500\r
    \r
    {"databases":[{\
    """)

    :gen_tcp.close(socket)
  end

  defp respond(socket, :closed_mid_headers) do
    :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-ty")
    :gen_tcp.close(socket)
  end

  defp respond(socket, :garbage) do
    :gen_tcp.send(socket, <<0, 1, 2, 3, "not http at all", 255, 254>>)
    :gen_tcp.close(socket)
  end

  defp respond(socket, :never_answers) do
    # Held open, and nothing sent. The client's own timeout is the only thing
    # that ends this, which is the point.
    receive do
      :never -> :ok
    after
      30_000 -> :gen_tcp.close(socket)
    end
  end

  defp respond(socket, :accept_and_reset) do
    :inet.setopts(socket, linger: {true, 0})
    :gen_tcp.close(socket)
  end
end
