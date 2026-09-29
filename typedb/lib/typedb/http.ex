defmodule TypeDB.HTTP do
  @moduledoc """
  The HTTP transport behaviour used by `TypeDB`.

  Three adapters ship with the driver:

  | Adapter | Backed by | Use when |
  | --- | --- | --- |
  | `TypeDB.HTTP.Finch` | Finch/Mint | the default; a pool per connection |
  | `TypeDB.HTTP.Req` | Req, over Finch | your app already configures HTTP through Req |
  | `TypeDB.HTTP.Httpc` | OTP's `:httpc` | you must run on OTP alone |

  Select one with the `:http` option when starting a connection:

      http: {TypeDB.HTTP.Req, []}

  ## Why Finch is the default

  Measured by `bench/transport.exs` against a local TypeDB 3.12.1, 400 requests
  per run with a warm pool:

  | Concurrency | `:httpc` | Req | Finch |
  | --- | --- | --- | --- |
  | 16 | 569 req/s, p50 28ms | 1656 req/s, p50 9ms | 2052 req/s, p50 7ms |
  | 64 | 437 req/s, p50 146ms | 1628 req/s, p50 38ms | 1830 req/s, p50 32ms |
  | 200 | 408 req/s, p50 336ms | 1675 req/s, p50 101ms | 1840 req/s, p50 100ms |

  `:httpc` does not scale with concurrency — three to four times slower
  throughout, with a p99 reaching 553ms where Finch's is 112ms. It remains
  supported, because running on OTP alone is sometimes worth that price, but it
  should be a deliberate choice.

  Run the script yourself: the ratio is the finding, and the absolute numbers
  belong to whatever machine produced them. This table used to carry 0.1.0's
  figures, including 77 req/s for `:httpc` at 200-way — a number that did not
  reproduce, was corrected in `README.md` and in the 0.6.0 changelog entry, and
  went on being published here.

  ## Implementing an adapter

  Four callbacks, two of them optional, and the optional two are the ones worth
  reading about.

  `c:init/2` runs once, inside the connection process, and may start pools or
  register profiles. Its return value is passed to every `c:request/6`, which is
  invoked **in the calling process** — adapters must therefore be safe to call
  concurrently from many processes. `c:request/6` must return
  `{:ok, response}` or `{:error, TypeDB.Error.t()}`; see `TypeDB.Error.new/3`
  for building one. Raising is contained rather than fatal, but it costs you the
  error kind, so returning is better.

  `c:owner/1` is optional and you almost certainly want it. Return the process
  your adapter cannot work without — a pool, a connection manager — and the
  connection links itself to it and stops when it dies, so a supervisor rebuilds
  both together. Return `nil` if there is no such process, as
  `TypeDB.HTTP.Httpc` does. Omit the callback entirely and your pool can die
  while the connection lives on, answering every later request with the same
  failure and never being restarted.

  `c:terminate/1` is optional and runs when the connection stops. Release
  anything `c:init/2` acquired. Do not rely on it for a pool you started *and*
  reported through `c:owner/1` — the link already takes that down with you.
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
  not, ignore it. `opts` is passed through from `:http`, so no adapter ever
  receives an option meant for a different one, with one addition: the
  connection's `:connect_timeout` is injected unless `:http` already carries a
  key of that name. Adapters that configure connecting once, at pool-build time,
  need it here — by the time `c:request/6` runs the pool already exists.
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

  @doc """
  Returns the process this adapter cannot work without, if it has one.

  The connection links itself to that process and shuts itself down when it dies,
  so that a supervisor can rebuild both together. Without this, an adapter whose
  pool has died keeps answering requests with raw exceptions instead of
  `TypeDB.Error`s, and nothing ever restarts it.

  Adapters that hold no process of their own — `TypeDB.HTTP.Httpc`, or
  `TypeDB.HTTP.Finch` pointed at a pool it does not own — return `nil`.
  """
  @callback owner(state()) :: pid() | nil

  @optional_callbacks terminate: 1, owner: 1
end
