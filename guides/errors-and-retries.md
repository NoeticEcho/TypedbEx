# Errors and retries

## What the driver retries for you

A request is retried when two things are true: the failure looks transient, and
re-sending the request is safe.

**Transient** means a transport failure, a timeout, or a response status in
`:retry_on_status` — `[429, 502, 503, 504]` by default. Those are a proxy or an
ingress answering while TypeDB restarts, or a server shedding load. Everything
else is TypeDB saying no, and saying it again will not help.

**Safe** is decided per operation, not per HTTP method — a read query and a
commit are both `POST`, and treating them alike would either lose recoverable
reads or re-send writes:

| retried | not retried |
| --- | --- |
| reads, one-shot and in-transaction | writes and schema changes |
| opening a `:read` transaction | opening a `:write` or `:schema` transaction |
| `analyze`, `rollback`, `close` | `commit` |
| `Database.create/2`, `User.set_password/3` | `User.create/3` |
| every `GET` and `DELETE` | |

The asymmetries are TypeDB's. Creating a database that exists is a no-op, so
re-sending is free; creating a *user* that exists is an error, so a re-send after
a lost response would report failure for a user that now exists. Opening a
`:read` transaction twice costs a pinned snapshot until TypeDB's own timeout;
opening a `:write` one twice costs the locks.

## What it does not, and cannot

A commit that TypeDB rejected is not retried and must not be. Neither is a whole
`transaction/5` block: the driver retries requests, and a block is not a request.
See [Transactions](transactions.html#what-commit-promises-and-when-it-does-not)
for the loop that does.

`TypeDB.Error.retryable?/1` answers "could retrying this help" for the layer
above — a job that should be requeued, a transaction that should be re-run:

```elixir
case TypeDB.transaction(conn, "social", :write, &steps/1) do
  {:error, %TypeDB.Error{} = error} ->
    if TypeDB.Error.retryable?(error), do: {:snooze, 5}, else: {:discard, error}

  result ->
    result
end
```

By the time you hold an error the driver has already retried whatever its
configuration allowed, so `true` does not mean it gave up early.

The case that makes this function worth having is an **isolation conflict**:
two concurrent `:write` transactions touched the same data, and the loser's
commit is rejected with code `STC2`. It is the one failure that is *certain* to
be worth another attempt, since the state it lost the race to is now committed —
and it arrives as a `400`, which is otherwise the driver's signal that a request
will fail identically forever. `TypeDB.Error.retryable_codes/0` is the list of
codes that override the status, and `STC2` is on it:

```elixir
defp with_retry(conn, attempts \\ 3) do
  case TypeDB.transaction(conn, "social", :write, &steps/1) do
    {:error, %TypeDB.Error{} = error} when attempts > 1 ->
      # The conflict invalidated the whole transaction, so this re-runs the
      # block against the state that won — it does not resend a request.
      if TypeDB.Error.retryable?(error), do: with_retry(conn, attempts - 1), else: {:error, error}

    result ->
      result
  end
end
```

Back off between attempts if the contention is real; two processes retrying a
conflict in lockstep will conflict again.

## Bounding the cost

Four options interact, and only one of them bounds the call:

```elixir
TypeDB.start_link(
  url: ...,
  timeout: 15_000,          # one attempt
  connect_timeout: 2_000,   # opening the socket
  max_retries: 3,           # extra attempts
  retry_max_delay: 2_000,   # one wait between attempts
  deadline: 20_000          # the whole call, retries and waits included
)
```

Without `:deadline`, that configuration can spend
`4 × (2_000 + 15_000) + 3 × 2_000 = 74 seconds` in your process. With it, twenty:
each attempt is given whichever is smaller, its own timeout or what the budget
has left, and a retry whose backoff would consume the rest is not started. The
error then says so, and carries the failure that prompted it.

Both are also per call, on every function that takes `:timeout`:

```elixir
TypeDB.Transaction.commit(tx, timeout: 60_000, deadline: 90_000)
```

Backoff is jittered — drawn uniformly from `0..base × 2ⁿ⁻¹` — so that callers who
failed together do not retry together. Pass a function to `:retry_backoff` when
you need a delay you can predict.

## Reading an error

```elixir
%TypeDB.Error{
  kind: :server,
  code: "TSV12",
  status: 404,
  message: "[TSV12] Operation failed: no open transaction.",
  reason: nil,
  body: nil
}
```

Branch on `:kind` and `:code`. Never on `:message` — the text is TypeDB's, it
changes, and the versioning policy does not cover it.

| kind | means |
| --- | --- |
| `:server` | TypeDB answered with a structured error. `:code` is stable |
| `:transport` | no HTTP response: refused, DNS, TLS, socket closed |
| `:timeout` | the request, or the whole call's `:deadline`, ran out |
| `:unauthenticated` | credentials rejected, or a token that cannot be renewed |
| `:decode` | the response was not what this driver expects |
| `:encode` | an Elixir term has no TypeDB representation. Raised, not returned |
| `:config` | the connection is misconfigured, or not running. Returned by `start_link/1`, raised by every other call |

Codes worth knowing, all verified against a live server:

| code | status | when |
| --- | --- | --- |
| `SRV3` | 400/404 | no such database |
| `TSV12` | 404 | the transaction has finished |
| `TSV2` | 400 | commit on a `:read` transaction |
| `TSV8` / `TSV9` | 400 | schema change in `:write`, write in `:read` |
| `TQL0` | 400 | the query does not parse |
| `INF2` | 400 | a type in the query is not in the schema |
| `CNT9` | 400 | a constraint such as `@key` was violated |
| `AUT1` / `AUT3` | 401 | bad credentials / rejected token |
| `STC2` | 400 | isolation conflict — re-run the transaction |
| `HSR2` | 400 | the request body is over TypeDB's 2 MiB limit |

A request far past that 2 MiB limit does not get `HSR2` at all: the server
closes the socket, and the driver can only report a `:transport` failure, which
`retryable?/1` calls retryable and `:max_retries` will re-send. There is no way
for the driver to tell that apart from a network blip — so a bulk load that
reproducibly "times out" is a batch that is too big. See
[Recipes](recipes.html#load-a-lot-of-rows) for batching by payload size.

## When the server restarts

An upgrade, a crash, a rolling deploy. Three things fail at the same instant:
the port stops answering, every socket the adapter had pooled is dead, and the
token the connection is holding may not be honoured by the process that comes
back.

The connection recovers by itself. You do not restart it, reopen it, or tell it
the server is back — and there is no supervision trick to add, because the
connection process does not hold the sockets. What callers see:

| when | what a caller gets |
| --- | --- |
| while it is down | `{:error, %TypeDB.Error{kind: :transport}}`, `:reason` carrying the adapter's own — `:econnrefused` and friends |
| the first call after the port reopens | succeeds |
| a transaction that was open | gone, uncommitted work included |

The last row is the one to design around. A transaction lives on the server, so
a restart takes it: both `query/3` and `commit/2` on a handle from before answer
`404 TSV12` — "no open transaction" — and the writes it held are not in the
database. That is the same code you get for using a transaction you already
committed, which is why `retryable?/1` says `false` for it: the driver cannot
tell "the server restarted under you" from "you kept a handle too long", and
re-running the second forever is worse than surfacing the first.

So a worker that must survive a restart re-runs the block rather than the
request — the loop in [What it does not, and
cannot](#what-it-does-not-and-cannot) — and treats `TSV12` as a reason to start
over, once:

```elixir
case TypeDB.transaction(conn, "social", :write, &steps/1) do
  {:error, %TypeDB.Error{code: "TSV12"}} when attempts > 1 ->
    # The transaction went away mid-flight. Nothing was committed, so this is
    # a fresh attempt rather than a re-send.
    with_retry(conn, attempts - 1)

  result ->
    result
end
```

Requests that were merely *in flight* need no such handling: they fail as
`:transport`, `:max_retries` re-sends the safe ones, and a read that lands after
the server is up is indistinguishable from one that never noticed.
`TypeDB.RestartIntegrationTest` stops a real server mid-traffic and starts it
again on every adapter, which is where those claims come from.

### When the connection restarts

The other direction: the connection process dies and its supervisor restarts it.
The configuration lives in an ETS table that process owns — that is what lets
requests run in the caller's process — so during the restart there is nothing to
read, and a call made in that window **raises** `%TypeDB.Error{kind: :config}`
rather than returning it.

That is deliberate, and it is the one place a `:kind` is raised for something
transient. A name that is not running is nearly always a typo or a child spec
that was never added, and returning an error for that would have every caller
handle a case that means "this code cannot work"; it is also what the ecosystem
does — calling a `GenServer` that is not running exits, and `Ecto` raises. The
message names both possibilities so that the transient one is not mistaken for
the permanent one.

The window is small. A thousand reads across a killed and restarted connection,
measured, produced one raise and 999 successes, and the name worked again
immediately. If your callers must not crash for it, wrap them — but under a
supervisor, letting them crash is usually right.

## Failing loudly

Every fallible function has a `!` twin that raises instead of returning:

```elixir
answer = TypeDB.query!(conn, "social", query, transaction_type: :read)
```

The exception is `transaction/5`, which returns whatever your block returned — a
bang form would have to guess whether an `{:error, _}` was yours or the commit's.

Some things raise with no twin at all, and deliberately: a transaction type that
is not one of three atoms, a `given_rows` value TypeDB has no representation for,
a misconfigured connection. Those are mistakes in your source rather than answers
from a server, and no amount of error handling makes them work. The rule is
written down in
[CONTRIBUTING](https://github.com/NoeticEcho/TypedbEx/blob/main/CONTRIBUTING.md).
