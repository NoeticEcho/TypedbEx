# Refactor plan

Derived from `AUDIT.md` at `b96ae98`. Ordered critical → major → minor. Each step is atomic: it
compiles, the suite passes, and the driver is shippable at the end of it. Each step is one commit.

## Gate applied after every step

```shell
mix format --check-formatted
mix compile --warnings-as-errors
mix test                                            # 247 unit tests
for a in finch req httpc; do TYPEDB_TEST_ADAPTER=$a mix test; done
mix credo --strict
mix dialyzer
```

Steps that touch the wire or the transport additionally run against the live server on :8000:

```shell
TYPEDB_INTEGRATION_URL=http://127.0.0.1:8000 mix test --include integration
```

Public API and wire contracts do not change except where a step says so explicitly (only step 9 does).

---

## Critical

### Step 1 — Make the Finch pool name collision-free (C1, m3)
**Problem:** `{:error, {:already_started, _}}` is treated as success, so a restarted connection adopts
a dead pool and fails every request forever.

**Change:** `lib/typedb/http/finch.ex`
- Derive the pool name per *instance*, not per connection name: `:"#{name}.Finch.#{unique}"`. That
  removes the race rather than papering over it — a restarting connection can never collide with the
  corpse of its predecessor.
- Delete the `:already_started` success branch; a genuine collision is now an error, returned as
  `%TypeDB.Error{kind: :config}` so the supervisor retries.
- An externally supplied `:name` keeps `owned?: false` as today.

**Files:** `lib/typedb/http/finch.ex`, `test/typedb/http_test.exs`

**Verify:** new test — start a connection under a `one_for_one` supervisor, `Process.exit(…, :kill)`,
wait for the restart, assert a request succeeds. Fails on today's code (reproduced in
`/tmp/probe3.exs`), passes after. Plus the gate.

**Risk:** pool names become non-deterministic, which shows up in Finch's own telemetry. Mitigated by
keeping the connection name as the prefix.

### Step 2 — Take the connection down when its transport dies (C2)
**Problem:** `trap_exit` is on with no `handle_info/2`, so a dead pool leaves the connection alive and
every request raises `ArgumentError`.

**Change:** `lib/typedb/connection.ex`
- Add `handle_info({:EXIT, pid, reason}, state)`: if `pid` is the adapter's process, stop the
  connection with that reason so the supervisor restarts it cleanly; log and ignore anything else.
- Record the adapter's pid in state at init (adapters gain an optional `owner_pid` in their state, or
  the connection monitors the name).

**Files:** `lib/typedb/connection.ex`, `test/typedb/connection_test.exs`

**Verify:** new test — kill the pool, assert the connection terminates and a supervisor brings both
back working. Depends on step 1 (the restart must work). Plus the gate.

---

## Major

### Step 3 — Contain adapter faults inside Transport (M4, M3)
**Problem:** a raising or contract-violating adapter escapes the `{:ok,_}/{:error,_}` contract; Finch
already raises on pool-checkout timeout.

**Change:** `lib/typedb/transport.ex` — wrap `adapter.request/6` so that a raise, an exit, a throw or a
return value outside the behaviour becomes `%TypeDB.Error{kind: :transport}` (pool exhaustion mapped to
`:timeout`), with the original reason preserved in `:reason`.

**Files:** `lib/typedb/transport.ex`, `test/typedb/http_test.exs`

**Verify:** tests with a raising adapter, a throwing adapter and one returning garbage; plus a
saturated-pool test asserting `%TypeDB.Error{kind: :timeout}` instead of a crash. Plus the gate.

### Step 4 — Honour `:connect_timeout` and unify timeout kinds (M2, M6)
**Problem:** under the default adapter `:connect_timeout` configures pool checkout, not connect; the
same event is reported as `:timeout` by Finch and `:transport` by Req and httpc.

**Change:**
- `lib/typedb/connection.ex` — pass the connection's `:connect_timeout` into the adapter's `init/2`
  opts, so pool-level connect options can be built from it.
- `lib/typedb/http/finch.ex` — set `conn_opts: [transport_opts: [timeout: connect_timeout]]` in
  `default_pool/1` unless the caller supplied their own `:conn_opts`; stop passing `:pool_timeout`
  from `:connect_timeout` (give pool checkout its own option with its own default).
- `lib/typedb/http/req.ex` — classify Mint/Finch timeout reasons as `kind: :timeout`.

**Files:** `lib/typedb/http/{finch,req}.ex`, `lib/typedb/connection.ex`, `lib/typedb/http.ex` (doc the
`init/2` opt), tests, `README.md`

**Verify:** unit test asserting the option reaches Finch's pool config; a tagged timing test against a
black-holed address (`198.51.100.1`) asserting all three adapters give up within ~1.5× the configured
budget and report `kind: :timeout` — this is the measurement in `/tmp/probe9.exs` turned into a test,
marked `:slow` so CI can opt in. Plus the gate.

### Step 5 — Fix `Enumerable` so `Enum.at/2` and `Enum.slice/2` work (M1)
**Problem:** both answer types raise `FunctionClauseError` on `Enum.at` and `Enum.slice`.

**Change:** `lib/typedb/answer.ex` — implement `slice/1` correctly for both impls
(`{:ok, length, &Enumerable.List.slice(list, &1, &2)}` shape, or `{:error, __MODULE__}` to fall back to
`reduce`). Prefer the real implementation so `Enum.at` stays O(1)-ish.

**Files:** `lib/typedb/answer.ex`, `test/typedb/query_test.exs`

**Verify:** table test over `count/at/slice/take/drop/member?/to_list` for `ConceptRows` **and**
`ConceptDocuments` — the latter has no `Enumerable` coverage today (m15). Reproduced in
`/tmp/verify1.exs`. Plus the gate.

### Step 6 — A queued token renewal must return an error, not exit (M5)
**Problem:** with a slow sign-in, callers queued behind it exceed the `GenServer.call` budget and exit.

**Change:** `lib/typedb/connection.ex` — catch the call exit and return
`%TypeDB.Error{kind: :timeout}`; base the call budget on the sign-in cost rather than the per-request
timeout, and document it.

**Files:** `lib/typedb/connection.ex`, `test/typedb/connection_test.exs`

**Verify:** the six-caller reproduction from `/tmp/verify3.exs` as a test: every caller must get an
`{:error, %TypeDB.Error{}}`, none may exit. Plus the gate.

### Step 7 — Validate URLs strictly (M7)
**Problem:** a mistyped port silently becomes 80; userinfo is dropped silently; malformed hosts are
mangled.

**Change:** `lib/typedb/config.ex` — reject a non-numeric or out-of-range port, reject a malformed
host, and reject (rather than silently drop) userinfo in the URL, pointing at `:username`/`:password`.

**Files:** `lib/typedb/config.ex`, `test/typedb/config_test.exs`

**Verify:** config tests for each input in the AUDIT M7 table. Plus the gate.

### Step 8 — Make the stub match the server on duplicate users (M9)
**Problem:** the stub always answers 200; the real server answers 400 `USC2`.

**Change:** `test/support/typedb_stub_router.ex` — 400 `USC2` on an existing user, with the
verified-against comment CONTRIBUTING requires; add a unit test and an integration test asserting the
same code from both.

**Files:** `test/support/typedb_stub_router.ex`, `test/typedb/admin_test.exs`,
`test/integration/typedb_integration_test.exs`, `README.md` (note that user creation, unlike database
creation, is not idempotent)

**Verify:** the new tests pass identically against stub and live server. Plus the gate.

### Step 9 — Bang variants — **needs your decision**
**Problem:** the moduledoc promises a `!` form for every function; `TypeDB.User` and `TypeDB.Server`
have none, and several are missing elsewhere.

Two ways out:

- **(a) Add the missing functions** — `User.{list!,get!,create!,set_password!,delete!}`,
  `Server.{health!,version!,servers!}`, `Database.{get!,schema!,type_schema!,create_if_not_exists!}`,
  `Transaction.{analyze!,rollback!,close!}`, and bang forms of the `TypeDB` delegates. Keeps the
  documented promise; grows the public API by ~15 functions before 0.1.0 is published.
- **(b) Narrow the documentation** — say bang variants exist "where noted" and list them. No new API.

I recommend **(a)**: the package is unpublished, so the API is still free to settle, and a
half-populated convention is worse than either extreme.

**Files:** (a) `lib/typedb/{database,user,server,transaction}.ex`, `lib/typedb.ex`, tests, `README.md`
— or (b) `lib/typedb.ex` and `README.md` only.

**Verify:** a test that every non-bang public function with an `{:ok,_}` return has a bang sibling
(generated from `__info__(:functions)`), so the convention cannot rot again.

---

## Minor

### Step 10 — Close the transaction when the commit request fails at transport level (m1)
`lib/typedb.ex` — in `finish/2`, close the transaction when `commit/1` fails with a `:transport` or
`:timeout` error (a server-rejected commit needs no close). Test with an adapter that fails only the
commit request.

### Step 11 — Correct `TypeDB.HTTP.Finch.terminate/1` (m2)
`lib/typedb/http/finch.ex` — keep the supervisor pid returned by `start_link` in the adapter state and
stop *that*, instead of `Process.whereis(name)` which is the Registry. Test asserts the pool is gone,
not restarted.

### Step 12 — Documentation truth pass (m4, m7, m8, m9, m10)
- Drop the `:closed` error kind, or implement client-side transaction state. **Recommend dropping** —
  the driver deliberately keeps no client-side transaction state.
- `lib/typedb/http/httpc.ex` — stop calling itself the default.
- `lib/typedb/http/req.ex` — stop calling itself "recommended for production"; fix the `:httpc`
  description.
- `mix.exs`, `README.md`, `lib/typedb/json.ex` — state the two real runtime dependencies.
- `lib/typedb/options.ex` — remove the false claim that `:transaction_timeout_millis` bounds the
  driver's own waiting, or implement it. **Recommend removing the claim**; `:timeout` already covers it.

### Step 13 — Make the vacuous tests test something (m11–m15)
- `connection_test.exs:114` — a real transport-retry test (adapter fails once, then succeeds; assert
  two attempts and the backoff).
- `http_test.exs:222` — assert the merged options of an actual request, not immutable init state.
- `token_renewal_integration_test.exs` — `@moduletag :skip` when unconfigured instead of reporting
  three passing tests that assert nothing.
- `telemetry_test.exs:115` — assert a real retry sequence, or delete the test.
- `answer.ex` `ConceptDocuments` — covered by step 5.

### Step 14 — Deduplicate and tidy (m5, m6, m16–m20)
- Extract `put_unless_nil/3`, `unwrap!/1` and path-segment encoding into one internal module.
- Give `Options.transaction_payload` the same `defaults` shape as `query_payload`.
- `mix typedb.check` — feed the file on stdin instead of argv; turn `File.read!` into a clean
  `Mix.raise`.
- `Duration.to_iso8601` — reject or normalise negative components.
- Delete the tracked `typeql-check.FAILED`.

### Step 15 — Contain adapter faults during sign-in too (C3, found during execution)
**Added after the plan was approved**, because step 6 exposed it: step 3 contained adapter faults
inside `TypeDB.Transport`, but `TypeDB.Connection.do_sign_in/1` calls the adapter directly and was
therefore never covered. Reproduced: a raising adapter kills the connection process, and the caller
gets `%TypeDB.Error{kind: :config, message: "... is not running"}` — which names neither the adapter
nor the fault.

**Change:** the containment from step 3 becomes `TypeDB.Transport.contain/3` and `do_sign_in/1` goes
through it.

**Files:** `lib/typedb/transport.ex`, `lib/typedb/connection.ex`, `test/typedb/connection_test.exs`

**Verify:** four adapters — raising, throwing, exiting, and returning garbage — each asserted to
leave the connection alive and usable, with the fault named in the error. Plus the gate.

---

## Sequencing notes

- Steps 1 → 2 are ordered: the EXIT handling in step 2 is only safe once restarts work.
- Step 3 must land before step 4, so that the new timeout paths surface as errors rather than crashes.
- Steps 10–14 are independent of each other and of everything above.
- If a step breaks the suite and cannot be fixed in two or three attempts, I will revert it, mark it
  **blocked** here with what went wrong, and move to the next.

## What I need from you

1. **Step 9** — bang variants: add the ~15 missing functions (my recommendation) or narrow the docs?
2. **Step 12** — drop the documented `:closed` error kind (my recommendation) or implement
   client-side transaction state to produce it?
3. Anything in `AUDIT.md` you want me to leave alone.
