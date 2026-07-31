defmodule TypeDB.HTTP do
  @moduledoc """
  The HTTP transport behaviour used by `TypeDB`.

  Three adapters ship with the driver:

  | Adapter | Backed by | Use when |
  | --- | --- | --- |
  | `TypeDB.HTTP.Finch` | Finch/Mint | the default; a pool per connection |
  | `TypeDB.HTTP.Req` | Req, over Finch | your app already runs a Finch through Req |
  | `TypeDB.HTTP.Httpc` | OTP's `:httpc` | you must run with no dependencies |

  Select one when starting a connection:

      TypeDB.start_link(url: "http://localhost:8000", http: {TypeDB.HTTP.Req, []})

  ## Why Finch is the default

  Measured against a local TypeDB 3.12.1, 400 requests per run:

  | Concurrency | `:httpc` | Finch |
  | --- | --- | --- |
  | 16 | 344 req/s, p50 45ms | 1729 req/s, p50 8ms |
  | 64 | 247 req/s, p50 263ms | 1773 req/s, p50 23ms |
  | 200 | 77 req/s, p50 2477ms | 1981 req/s, p50 19ms |

  `:httpc` does not degrade gracefully — throughput *falls* as concurrency rises,
  and tail latency reaches seconds. It remains supported, because running with no
  dependencies is sometimes worth that price, but it should be a deliberate
  choice.

  ## Implementing an adapter

  `c:init/2` runs once, inside the connection process, and may start pools or
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

  `name` is the connection's registered name. Adapters that own named resources
  derive them from it so that two connections never collide; adapters that do
  not, ignore it. `opts` is passed through verbatim from `:http`, so no
  adapter ever receives an option meant for a different one.
  """
  @callback init(name :: atom(), opts :: keyword()) :: {:ok, state()} | {:error, term()}

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
