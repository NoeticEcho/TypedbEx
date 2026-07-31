# Audit — TypeDB Elixir driver

Audited at `b96ae98` (main). Method: seven parallel auditors, one per category, each finding then
handed to an independent reviewer whose job was to refute it; 46 raw findings, 18 refuted, 28
confirmed. Every finding below was additionally **reproduced by running code** or by reading the cited
line — the reproduction script is named where one exists.

Duplicates reported by more than one auditor have been merged.

> **All findings below are fixed.** The refactor ran as `REFACTOR_PLAN.md` sequenced it, in fifteen
> commits from `0e5b005` to `babcbe3`. See [Status after the refactor](#status-after-the-refactor) at
> the end for what changed where, what was found along the way, and what is left for you to decide.
> The findings are kept in their original wording so the fixes can be checked against them.

## Reference: what the driver must do

Taken from README.md, CONTRIBUTING.md, the moduledocs and mix.exs.

1. Connect to TypeDB 3.x over HTTP API v1; config = URL + username/password or a pre-issued token;
   supervised; several named connections at once.
2. Auth: lazy sign-in, proactive renewal from the JWT's own lifetime, reactive renewal on `401`
   bounded by `:max_auth_renewals`, concurrent renewals collapsed, credentials never leaked.
3. Full API v1 coverage: signin, health, version, servers, databases, users, transactions, one-shot
   `/query`, analyze.
4. Requests run in the caller's process; the connection process is not a throughput bottleneck.
5. Answers decode into `Ok` / `ConceptRows` / `ConceptDocuments`; concepts into structs; rows
   implement `Access`; answers implement `Enumerable`; values convert to native Elixir terms.
6. `given_rows` encoded in TypeDB's tagged wire form, so any input is injection-safe.
7. Every failure is a `%TypeDB.Error{}` with a `:kind` and TypeDB's stable `:code`; every operation
   has a `{:ok,_}/{:error,_}` form and a `!` form.
8. Pluggable transport; Finch default, Req and httpc alternatives; TLS verified by default in all three.
9. Pluggable JSON codec; telemetry spans for requests and sign-ins.
10. `TypeDB.transaction/5` commits on success, rolls back on error/raise/throw/exit, closes a `:read`.

---

## 1. Critical

### C1 — A supervised connection never recovers from a restart
`lib/typedb/http/finch.ex:77`

`start_pool/2` treats `{:error, {:already_started, _pid}}` as success and marks the pool `owned?: true`.

Finch's registered name is not released synchronously when the pool dies. Reproduced
(`/tmp/probe5.exs`): after killing a named Finch **and receiving its `:DOWN`**, `Finch.start_link/1`
with the same name still answers `{:error, {:already_started, …}}`, and the registry is then gone for
good (`Process.whereis` → `nil` 300 ms later).

So when a supervisor restarts a crashed connection, `init/1` adopts a corpse and reports success.
Reproduced end to end (`/tmp/probe3.exs`): under `one_for_one`, a killed connection comes back and
then fails **every** request permanently with `ArgumentError: unknown registry` raised from inside
Finch — not a `%TypeDB.Error{}`.

*Impact:* the driver does not survive the single most basic OTP failure mode.

### C2 — The connection traps exits but handles none
`lib/typedb/connection.ex:191`

`Process.flag(:trap_exit, true)` is set, but the module defines only `init/1`, `handle_call/3` and
`terminate/2` — there is **no `handle_info/2`**.

Reproduced (`/tmp/supervision_probe.exs`): killing the Finch pool leaves the connection alive; the
`{:EXIT, …}` is swallowed by the default `use GenServer` handler ("received unexpected message"); every
later request raises `ArgumentError` out of Finch instead of returning `{:error, %TypeDB.Error{}}`.

*Impact:* a dead transport is never noticed and never recovered from, and breaks the documented
promise that every failure is a `TypeDB.Error`.

---

## 2. Major

### M1 — `Enum.at/2` and `Enum.slice/2` crash on every answer
`lib/typedb/answer.ex:59` (`ConceptRows`), `lib/typedb/answer.ex:77` (`ConceptDocuments`)

Both `Enumerable` impls define `slice/1` as `Enumerable.List.slice(rows)`, which does not satisfy the
`slice/1` contract for a wrapper struct.

Reproduced (`/tmp/verify1.exs`):

| call | result |
| --- | --- |
| `Enum.count/1`, `Enum.map/2`, `Enum.take/2`, `Enum.member?/2` | work |
| `Enum.at(answer, 0)` | **`FunctionClauseError`** |
| `Enum.slice(answer, 0..0)` | **`FunctionClauseError`** |

README.md:173 says both types "are `Enumerable`, so they pipe straight into `Enum` and `Stream`".
Two of the most-used `Enum` functions raise.

### M2 — `:connect_timeout` is ignored by the default adapter
`lib/typedb/http/finch.ex:117`

`:connect_timeout` is passed to Finch as `:pool_timeout`, which is the *checkout-from-pool* timeout
(`deps/finch/lib/finch.ex:858`). Finch's real connect timeout is `conn_opts: [transport_opts:
[timeout: …]]`, defaulted to 5000 ms; the adapter never sets it.

Measured (`/tmp/probe9.exs`, connecting to black-holed `198.51.100.1` with `connect_timeout: 1_000`):

| adapter | gave up after | reported kind |
| --- | --- | --- |
| **finch (default)** | **5027 ms** | `:timeout` |
| req | 1016 ms | `:transport` |
| httpc | 1051 ms | `:transport` |

Two defects in one: the documented option (README.md:286, `config.ex:20`) silently configures
something else under the default transport, and the same physical event is reported with a different
`:kind` per adapter — while README.md:272 tells users to branch on `:kind`.

### M3 — Finch raises on pool-checkout timeout, crashing the caller
`lib/typedb/http/finch.ex:119`

Reproduced (`/tmp/verify2.exs`): with a saturated pool, `Finch.request/3` **raises**
`RuntimeError "Finch was unable to provide a connection within the timeout…"` rather than returning
`{:error, _}`. The adapter only handles `{:error, reason}`, so the exception escapes to the caller.

Made more likely by M2: a user who sets a short `:connect_timeout` is really shortening the pool
checkout budget.

### M4 — Adapter exceptions and contract violations are not contained
`lib/typedb/transport.ex:151`

`config.http_adapter.request/6` is called bare. Reproduced (`/tmp/probe6.exs`): an adapter that raises
propagates `RuntimeError` to the caller; one that returns a value outside the behaviour contract
produces `FunctionClauseError`. `TypeDB.HTTP` is public and user-implementable, so this is reachable
without any bug in the shipped adapters — and M3 shows a shipped adapter already hits it.

### M5 — Queued token renewals exit instead of returning an error
`lib/typedb/connection.ex:151`

`renew_token/2` calls the connection with a budget of `config.timeout + 5s`. Renewals are serialised
in the GenServer, so with a slow sign-in the callers queued behind exceed their own budget.

Reproduced (`/tmp/verify3.exs`, sign-in delayed 2 s, `timeout: 1_000`, six concurrent callers): five
callers received `{:error, %TypeDB.Error{}}`; the sixth **exited** with a `GenServer.call` timeout.
A caller process crashes rather than receiving an error it can match on.

### M6 — The Req adapter never produces `:timeout`
`lib/typedb/http/req.ex:67`

Every failure — including receive and connect timeouts — is classified `kind: :transport`. Confirmed by
the M2 measurement. `TypeDB.Error`'s docs and README.md:272 present `:timeout` as a kind users branch
on; under Req it never occurs.

### M7 — URL parsing silently discards or mangles input
`lib/typedb/config.ex:170`

Reproduced (`/tmp/probe6.exs`):

| input | accepted as |
| --- | --- |
| `"http://host:abc"` | `"http://host"` — a mistyped port silently becomes 80 |
| `"http://user:pw@host:8000"` | `"http://host:8000"` — credentials dropped without a word |
| `"http://[bad"` | `"http://bad"` — mangled rather than rejected |
| `"http://host:99999999"` | accepted, though no such port exists |

`TypeDB.Config.new/1` exists to reject bad configuration; here it launders it.

### M8 — The documented `!` variants mostly do not exist
`lib/typedb.ex:54`, `lib/typedb/user.ex`, `lib/typedb/server.ex`

The moduledoc states without qualification: "Every function has a `{:ok, _} | {:error, …}` form and a
`!` form that raises." In fact only seven exist. `TypeDB.User` and `TypeDB.Server` have **none**;
`TypeDB.Database` is missing `get!/schema!/type_schema!`; `TypeDB.Transaction` is missing
`analyze!/rollback!/close!`; the convenience delegates on `TypeDB` (`health/1`, `version/1`,
`databases/1`, `create_database/2`, `delete_database/2`) have none.

Following the documentation produces `UndefinedFunctionError`.

### M9 — The stub disagrees with the server on duplicate user creation
`test/support/typedb_stub_router.ex:124`

The stub answers 200 for every `POST /v1/users/:username`. Verified against live TypeDB 3.12.1:
creating an existing user returns **400 `USC2` "User already exists"**. Unlike databases — where a
duplicate create really is a no-op, and README.md:244 says so — user creation is *not* idempotent.

No test covers the case and no doc mentions it, so `TypeDB.User.create/3` behaves one way in the suite
and another in production. (Checked and **not** a divergence: `PUT /v1/users/:unknown` really is 404;
an earlier 400 was TypeDB rejecting a too-short password.)

---

## 3. Minor

### Gaps and small bugs

| # | Where | Problem |
| --- | --- | --- |
| m1 | `lib/typedb.ex:241` | `transaction/5` leaks the server-side transaction when the **commit request itself** fails at transport level: `finish/2` returns the error without closing. (A *server-rejected* commit is fine — verified `/tmp/probe10.exs`: the server has already finished the transaction.) |
| m2 | `lib/typedb/http/finch.ex:102` | `terminate/1` does `Process.whereis(name)`, which is Finch's **Registry**, not the supervisor `start_link` returned. Stopping it merely makes the supervisor restart it — verified `/tmp/verify2.exs`, the pid changes rather than disappearing. Harmless in practice because the pool is linked to the connection and dies with it (verified `/tmp/verify3.exs`: no leak after `TypeDB.stop/1`), but the code does not do what it says. |
| m3 | `lib/typedb/http/finch.ex:77` | Same line as C1: even when the adopted pool is genuinely someone else's, it is marked `owned?: true` and would be shut down on terminate. |
| m4 | `lib/typedb/error.ex:39` | The `:closed` kind is documented in `TypeDB.Error` and README.md:272 but is never constructed anywhere in `lib/`; there is no client-side transaction state that could detect it. |
| m5 | `lib/mix/tasks/typedb.check.ex:88` | The whole file is passed as an argv element; a large `.tql` will exceed `ARG_MAX`. `typeql-check` reads stdin precisely for this. `File.read!` also raises `File.Error` instead of a clean `Mix.raise`. |
| m6 | `lib/typedb/duration.ex` | `to_iso8601(%Duration{months: -14})` emits `"P-1Y-2M"`, which `parse/1` then rejects. Only reachable through hand-built structs; TypeDB durations are non-negative. |

### Documentation contradicting the code

| # | Where | Problem |
| --- | --- | --- |
| m7 | `lib/typedb/http/httpc.ex:3` | Moduledoc still calls itself "Default `TypeDB.HTTP` adapter" — left over from before Finch became the default. |
| m8 | `lib/typedb/http/req.ex:5` | Moduledoc says Req is "Recommended for production" (it is not the default) and describes `:httpc` as giving "a global profile", which the httpc adapter's own docs contradict. |
| m9 | `mix.exs:45`, `README.md:28`, `lib/typedb/json.ex:5` | Three places claim zero or one runtime dependency. `mix.exs` requires **two**: `:finch` and `:telemetry`. |
| m10 | `lib/typedb/options.ex:8` | `:transaction_timeout_millis` is documented as "the ceiling for how long it waits on transaction requests". Nothing reads it for that; `Transport` uses `opts[:timeout] || config.timeout`, and `commit/rollback/close` pass no timeout at all. |

### Tests that do not test what they claim

| # | Where | Problem |
| --- | --- | --- |
| m11 | `test/typedb/connection_test.exs:114` | "retries idempotent requests" never causes a retry — it asserts that a 503 is *not* retried. `:max_retries` and `:retry_backoff` have no coverage at all. |
| m12 | `test/typedb/http_test.exs:222` | The test guarding "a per-request connect timeout must not wipe out a pinned CA" asserts on immutable `init` state; it would pass if the guard it protects were deleted. |
| m13 | `test/integration/token_renewal_integration_test.exs:78` | All three tests short-circuit on `context[:skip]` and report **passing** when the env var is unset — which is the case in CI. Three green tests that assert nothing. |
| m14 | `test/typedb/telemetry_test.exs:115` | "each retry gets its own span, numbered" asserts `attempt >= 1`, a tautology, and its own comment concedes it never sees an attempt above 1. |
| m15 | `lib/typedb/answer.ex:77` | `ConceptDocuments`'s `Enumerable` impl has no test at all — which is why M1 went unnoticed. |

### Duplication and inconsistency

| # | Where | Problem |
| --- | --- | --- |
| m16 | `lib/typedb.ex:282`, `lib/typedb/transaction.ex:252` | `put_unless_nil/3` defined twice. |
| m17 | `lib/typedb/transaction.ex:255`, `lib/typedb/database.ex:149` | `unwrap!/1` defined twice. |
| m18 | `lib/typedb/database.ex:147`, `lib/typedb/user.ex:95` | Percent-encoding `encode/1` defined twice. |
| m19 | `lib/typedb/options.ex:73` | `query_payload/2` takes connection defaults, `transaction_payload/1` does not; the two struct paths convert differently (map vs keyword list) for the same job. |
| m20 | `typeql-check.FAILED` | An empty file predating the first commit, swept in by `git add -A` and now tracked on `main`. |

---

## Refuted findings

Eighteen raw findings were rejected by the adversarial pass. Recorded so they are not re-raised:
claims that concept decoding drops unknown fields (it does not — unknown kinds raise a
`:decode` error by design), that `given_rows` accepts unsafe raw JSON (the driver always tags), that
database creation should error on duplicates (verified server behaviour is a no-op), that closing an
unknown transaction should 404 (the server returns 200), that the connection serialises requests (it
does not — only token minting), and assorted style preferences.

---

## Status after the refactor

Audited at `b96ae98`; refactor executed in fifteen commits, `0e5b005` … `babcbe3`. **All 31 findings
are fixed** — the 28 from the audit plus three found while executing (C3, and the two extra stub
inaccuracies folded into M9).

Every step ran the same gate before being committed: `mix format --check-formatted`,
`mix compile --warnings-as-errors`, `mix test` under all three HTTP adapters, `mix credo --strict`,
`mix dialyzer`, and the integration suite against a live TypeDB 3.12.1. Final state: **307 unit tests
× 3 adapters, 346 with integration**, credo clean, dialyzer clean.

### Fixed

| Finding | Commit | What changed |
| --- | --- | --- |
| C1 | `0e5b005` | Finch pools are named per *instance*, so a restarted connection cannot adopt its predecessor's corpse. |
| C2 | `aeb4df6` | The connection links to the adapter's owning process and stops when it dies, so a supervisor rebuilds both. |
| M1 | `5d40738` | `Enumerable.slice/1` returns the backing list instead of delegating to `Enumerable.List`, which sent `Enum` into a reduce that could not take the struct. `Enum.at/2` and `Enum.slice/2` work on both answer types. |
| M2 | `ad44ee1` | `:connect_timeout` reaches Mint through the pool's `transport_opts`, where it is actually read. Measured against a black hole: 5040 ms → 1002 ms for a 1000 ms budget. |
| M3, M4 | `b15b8aa` | Every adapter call goes through fault containment: a raise, throw, exit or nonsense return becomes a `%TypeDB.Error{}`. Pool exhaustion classifies as `:timeout`. |
| M5 | `2269065` | A renewal that overruns returns `%TypeDB.Error{kind: :timeout}` instead of exiting the caller, and the call budget is derived from what a sign-in costs rather than from the per-request timeout. |
| M6 | `ad44ee1` | Req and httpc classify a timeout as `:timeout`, as Finch already did, so the kind no longer depends on the adapter. |
| M7 | `78cc002` | URLs are parsed with `URI.new/1` and the port, host and userinfo checked explicitly. All four laundering cases are now errors; IPv6 literals keep their brackets. |
| M8 | `2a5812a` | The ~15 missing `!` variants exist, and a test generated from the typespecs keeps the convention from rotting. `TypeDB.transaction/5` is exempt, and says why. |
| M9 | `b19e061` | The stub emulates the server's real user-endpoint codes — `SRV4`, `USC2`, `USU4`, `USD3` — all read off a live server, and an integration test asserts the same ones so the two cannot drift. |
| m1 | `241f6d0` | A commit that fails at transport level closes the transaction instead of leaving it holding locks. |
| m2, m3 | `29f86f3`, `0e5b005` | `terminate/1` stops the supervisor `start_link` returned, not the registry; an adopted external pool is never marked owned. |
| m4, m7–m10 | `0249ff1` | Documentation truth pass: the `:closed` kind is gone, httpc no longer calls itself the default, Req no longer claims to be faster, the two real runtime dependencies are stated, and `:transaction_timeout_millis` no longer claims to bound the driver. |
| m5, m6, m16–m20 | `1751ec1` | `typeql-check` gets its input on stdin (a 1.4 MB schema: exit 7 through argv, 0 through stdin); negative durations raise instead of emitting unparseable ISO-8601; the duplicated helpers live in `TypeDB.Wire` and `TypeDB.Bang`; `Options` has one payload path; the stray tracked file is gone. |
| m11–m15 | `01f850a`, `5d40738` | The four vacuous tests now drive real retries, real spans and real option merges; the token-renewal suite skips instead of reporting green; `ConceptDocuments` has `Enumerable` coverage. |

### Found while executing

| # | Where | Problem | Commit |
| --- | --- | --- | --- |
| C3 | `lib/typedb/connection.ex` | `do_sign_in/1` called the adapter directly, so the containment added for M4 did not cover it — and this code runs *inside* the connection process. A raising adapter killed the connection, and the caller got `kind: :config, "… is not running"`, naming neither the adapter nor the fault. Found while writing the M5 test. | `babcbe3` |
| M9b | `test/support/typedb_stub_router.ex` | Checking the user endpoint for M9 turned up three more disagreements: the stub answered a single invented `USR2` where the server uses `SRV4` on GET, `USU4` on PUT and `USD3` on DELETE. | `b19e061` |

### Deliberately not done

- **`:pool_timeout` has no connection-level option.** It is set per adapter
  (`http: {TypeDB.HTTP.Finch, pool_timeout: …}`), not on the connection, because it is a Finch concept
  — httpc has no equivalent and Req's belongs to Req. Promoting it would put an option on every
  connection that two of the three adapters ignore.
- **`TypeDB.transaction/5` has no `!` variant.** It returns whatever the block returned, so its
  `{:error, _}` may be the caller's own value and not an exception at all. A bang form would have to
  guess whether to raise it. Recorded as the single exemption in `test/typedb/api_convention_test.exs`,
  which asserts the exemption still names a real function.
- **The `:slow` tests are opt-in.** They wait out real timeouts, so `mix test` stays quick and hermetic;
  CI runs them via `TYPEDB_SLOW_TESTS=1` in the job that already takes seconds.

### For your decision

Nothing is blocking, but three things are judgement calls you may want to overrule:

1. **The `:closed` error kind is gone** (you approved this). If you would rather have it, it means
   client-side transaction state — the driver currently holds none by design, and adding it would make
   `close/1` and `commit/1` mutate a struct the caller holds by value.
2. **`Duration.to_iso8601/1` now raises on a negative component** rather than emitting `"P-1Y-2M"`.
   Raising from a rendering function is a strong choice; the alternative is returning
   `{:error, reason}` and changing the signature, or normalising silently. Only reachable from a
   hand-built struct — TypeDB never sends one.
3. **`mix typedb.check` shells out through `sh -c`** to reach the child's stdin, which neither
   `System.cmd/3` nor Erlang ports can do. The file path travels as a positional argument, so
   filenames are data rather than script, but the task now needs a POSIX shell — it will not run on
   Windows without one.
