defmodule TypeDB.HTTP do
  @moduledoc """
  The HTTP transport behaviour used by `TypeDB`.

  The default adapter, `TypeDB.HTTP.Httpc`, is built on OTP's `:httpc` and keeps
  the driver dependency-free. `TypeDB.HTTP.Req` is provided for applications that
  already use [Req](https://hex.pm/packages/req) and want a single, pooled HTTP
  stack.

  Select an adapter when starting a connection:

      TypeDB.start_link(url: "http://localhost:8000", http: {TypeDB.HTTP.Req, []})

  ## Implementing an adapter

  `c:init/1` runs once, inside the connection process, and may start pools or
  register profiles. Its return value is passed to every `c:request/6`, which is
  invoked **in the calling process** — adapters must therefore be safe to call
  concurrently from many processes.
  """

  @type method :: :get | :post | :put | :delete
  @type headers :: [{String.t(), String.t()}]
  @type state :: term()

  @type response :: %{
          status: pos_integer(),
          headers: headers(),
          body: binary()
        }

  @type request_opts :: [timeout: timeout(), connect_timeout: timeout()]

  @doc """
  Initialises adapter state. Called once from the connection process.
  """
  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  Performs a request. Called concurrently from arbitrary caller processes.

  `body` is `nil` for requests without a payload. Implementations must not
  follow redirects and must not raise on non-2xx statuses.
  """
  @callback request(
              state(),
              method(),
              url :: String.t(),
              headers(),
              body :: iodata() | nil,
              request_opts()
            ) :: {:ok, response()} | {:error, TypeDB.Error.t()}

  @doc """
  Releases adapter resources. Called when the connection process terminates.
  """
  @callback terminate(state()) :: :ok

  @optional_callbacks terminate: 1
end
