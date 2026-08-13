# Refactor plan IV — Audit VI, both packages

Nine findings: four major, five minor, no critical. Ordered by severity, then by
how much of the codebase a step touches. Each step leaves both packages working
and is committed on its own.

## The gate, after every step

From the package the step touched, and from both when it touched shared code:

```sh
mix format --check-formatted
mix credo --strict
mix dialyzer
mix test                                   # typedb: once per adapter, finch|req|httpc
TYPEDB_GRPC_ADDRESS=127.0.0.1:1729 mix test --include integration
TYPEDB_INTEGRATION_URL=… TYPEDB_GRPC_ADDRESS=… mix test --include integration test/behaviour
```

A step that changes the export file format or its error paths also runs the
console interop test with `TYPEDB_CONSOLE` set.

## Step 1 — a failed export leaves nothing behind (VI-2, VI-3) — major

**Changes.** `write_export/3` opens both files under one cleanup path instead of
a `with` that can leak the first, and `drain_export/3` halts on a write failure
instead of draining the rest of the export into a file that is already failing.

**Files.** `typedb_grpc/lib/typedb/grpc/database.ex`,
`typedb_grpc/test/integration/migration_integration_test.exs`.

**Verification.** A new integration test asserting what was measured in the
audit: exporting to a data path whose directory does not exist returns a
`:config` error **and** leaves no schema file. It fails on today's code — that is
the point of writing it first. The existing "exporting a database that is not
there leaves no files behind" test covers the other order.

## Step 2 — a corrupt data file is refused on the first chunk (VI-4) — major

**Changes.** A ceiling on the declared item length in `TypeDB.GRPC.Migration`.
Anything above it is not a truncated export, so it is refused with `:decode`
immediately rather than after buffering the file. The ceiling is a module
attribute with the reasoning beside it: TypeDB's migration items are entities,
attributes and relations, so 64 MiB is orders of magnitude above any real one
and orders below a memory problem.

**Files.** `typedb_grpc/lib/typedb/grpc/migration.ex`,
`typedb_grpc/test/typedb/grpc/migration_test.exs`.

**Verification.** A unit test writing a delimiter that declares 32 GiB followed
by a few megabytes, asserting the error arrives having read one chunk rather
than the file — measured as bytes actually consumed, not as wall clock. Plus the
existing round-trip and console-interop tests, unchanged, to prove the ceiling
refuses nothing real.

## Step 3 — the streamed-read buffer stops being quadratic (VI-7) — major

**Changes.** `on_part/3` prepends decoded rows to the buffer and `serve_stream/3`
reverses when it hands them over, which is the shape `build_answer/1` already
uses. Order of rows as seen by the consumer must not change.

**Files.** `typedb_grpc/lib/typedb/grpc/transaction.ex`,
`typedb_grpc/test/integration/stream_integration_test.exs`.

**Verification.** Two things, because either alone is insufficient: the existing
streaming suite proves the order is unchanged, and a new test reads 20 000 rows
with `prefetch_size: 20_000` and asserts it is no slower than the same read at
the default prefetch. Today that ratio is 1.76×; the assertion is written with
enough headroom to be stable on a loaded runner but would fail on today's code.

## Step 4 — say when credentials are about to cross the network in the clear (VI-8) — minor

**Changes.** `TypeDB.GRPC.Connection` logs a warning, once per connection, when
`tls: false` and the address is not loopback. The default does not change: it
matches TypeDB CE's own, and changing it would break every working local
configuration to fix a case the message covers.

**Files.** `typedb_grpc/lib/typedb/grpc/connection.ex`,
`typedb_grpc/lib/typedb/grpc/config.ex` (a `loopback?/1` predicate),
`typedb_grpc/test/typedb/grpc/config_test.exs`.

**Verification.** Unit tests for the predicate over `127.0.0.1`, `localhost`,
`::1`, a hostname and a routable address, plus an integration test asserting the
warning is *absent* for the loopback server the suite runs against — a warning
every local user sees is a warning nobody reads.

## Step 5 — an abandoned streamed read is collected (VI-5) — minor

**Changes.** When `stream_next/3` times out, tell the transaction to drop that
request's accumulator, the way `stream_cancel/2` already does for a stream the
consumer finished with.

**Files.** `typedb_grpc/lib/typedb/grpc/transaction.ex`,
`typedb_grpc/test/integration/stream_integration_test.exs`.

**Verification.** An integration test that starts a stream, times a `stream_next`
out, and asserts `:sys.get_state(tx.pid).pending` no longer holds it — the same
technique the back-pressure test uses, and for the same reason: nothing else can
see this.

## Step 6 — the documentation stops being wrong (VI-1, VI-6, VI-9) — minor

**Changes.** Three corrections, no behaviour:

* `TypeDB.GRPC.Transaction`'s moduledoc drops the paragraph saying constant-
  memory streaming is not done, and points at `stream/3` instead.
* `send_reqs/2` gains the sentence that says what it actually does — one message
  per request, the pipelining coming from not waiting rather than from the
  repeated field. (Batching them is a behaviour change and is **not** in this
  plan; if it is wanted it is its own measured step.)
* `AUDIT.md`'s index stops linking to a section that does not exist: Audit IV
  gets the one-paragraph summary the CHANGELOG already carries, so the link
  points at something.

**Files.** `typedb_grpc/lib/typedb/grpc/transaction.ex`, `AUDIT.md`.

**Verification.** `mix docs` builds without new warnings; the audit's own link
resolves. Nothing to test at runtime, which is why this step is last among the
ones that are being done.

## Not doing, and why

**VI — the symlink case in `export_to_files/5`.** Comparing `Path.expand/1` does
not catch the same file reached through a symlink or a hard link. Rust compares
paths too. The failure is loud and immediate — the data file overwrites the
schema and the import that follows cannot parse it — and closing it properly
means `File.stat` on both paths and comparing inode and device, which is another
system call on every export to catch a mistake nobody has made. Recorded as a
decision rather than an oversight.

**VI — batching `Transaction.Client.reqs`.** A real improvement and a real
behaviour change: it alters how requests reach the server and could interact
with the TSV13 write behaviour the moduledoc documents at length. It needs its
own measurement, not a line in a documentation step. Filed as a bead.

## Order and dependencies

None of the six steps depends on another. They are ordered by severity, so
stopping after any of them leaves the more serious things fixed. Steps 1 and 2
both touch the export path and are kept apart because they fail differently and
their tests are independent.

---

# Refactor plan III — Audit V, `typedb_grpc`

**Executed in full at `bb08ff1`.** Six steps, six commits, nothing blocked and
nothing rolled back. See `AUDIT.md`'s Audit V for the outcome table.

Nine findings, ordered critical → major → minor. Each step leaves both packages
building and both suites green, and is committed on its own.

**Gate after every step**, from the package directory:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer
TYPEDB_GRPC_ADDRESS=127.0.0.1:1729 TYPEDB_INTEGRATION_URL=http://127.0.0.1:8000 \
  mix test --include integration
```

**Rollback rule.** A step whose tests cannot be made green in two or three
attempts is reverted, marked `blocked` here, and the next step proceeds.

**Public API.** Two steps change it, and both say so: step 5 adds `!` twins
(additive), step 6 makes `close/2` honour its options (behavioural). Nothing
else touches the surface.

| # | Finding | Severity | Version impact |
| --- | --- | --- | --- |
| 1 | V-1, V-9 — `datetime-tz` decodes wrongly; no temporal coverage | critical | none, package unreleased |
| 2 | V-3 — concurrent callers on one transaction | critical | none |
| 3 | V-5 — `connection: nil` in telemetry | major | none |
| 4 | V-4 — `from_url/1` port heuristic | major | none |
| 5 | V-2 — missing `!` twins | major | additive |
| 6 | V-6, V-7, V-8, V-10 — dead code and an ignored parameter | minor | `close/2` gains behaviour |

## Step 1 — `datetime-tz`, and the coverage that would have caught it

**Changes.** `Decode.scalar/2` for `:datetime_tz` builds a
`%TypeDB.DateTimeTZ{}` — the sibling's struct — from the protobuf's naive
instant plus its zone or offset, rather than a `DateTime` with the offset
stamped on. `:datetime` and `:duration` are checked against the sibling at the
same time, since they are decoded by the same neighbourhood of code.

**Files.** `typedb_grpc/lib/typedb/grpc/decode.ex`,
`typedb_grpc/test/behaviour/shared_behaviour_test.exs`.

**Verify.** A new shared-suite test round-trips every temporal type through both
drivers and asserts they agree. It must fail before the fix and pass after.

## Step 2 — one transaction, many callers

**Changes.** Replace the single `awaiting` slot with a per-request map from
`req_id` to the caller waiting on it, so concurrent calls on one handle are
independent. The timeout path must then close only the request it owns, not the
transaction.

**Files.** `typedb_grpc/lib/typedb/grpc/transaction.ex`,
`typedb_grpc/test/integration/transaction_integration_test.exs`.

**Verify.** Two `Task`s querying one handle both answer. Non-vacuity by
reverting to the single slot and watching it fail.

## Step 3 — the connection name reaches the telemetry

**Changes.** Carry the connection on `%Transaction{}` so the stream-batch event
can report it. The struct gains a field; it is not part of any documented
pattern match.

**Files.** `typedb_grpc/lib/typedb/grpc/transaction.ex`,
`typedb_grpc/test/integration/telemetry_integration_test.exs`.

**Verify.** The telemetry test asserts `metadata.connection` is the connection
name rather than `nil`.

## Step 4 — `from_url/1`

**Changes.** Decide the port from the parsed URI rather than from a substring of
the raw string, and parse once.

**Files.** `typedb_grpc/lib/typedb/grpc/config.ex`, plus a unit test file for
`Config` — the package has none, which is its own small gap.

**Verify.** Unit tests over the shapes that break the current version: a path
containing `:80`, an IPv6 host, an explicit `:443`, no port at all.

## Step 5 — `!` twins

**Changes.** Every public function that returns `{:error, %TypeDB.Error{}}`
gains a `!` twin that raises, matching the sibling's convention. The sibling
generates them with the `TypeDB.Bang` macro for a documented reason — a shared
`unwrap!/1` widens every caller's success type and Dialyzer then reports
`missing_range` on all of them — so the same approach is used here.

**Files.** all of `typedb_grpc/lib/typedb/grpc/`, plus a convention test
mirroring `typedb`'s.

**Verify.** A test that enumerates the public surface and asserts the pairing,
so the next function added cannot forget.

## Step 6 — dead code and the ignored parameter

**Changes.** Delete `lifetime_margin/1`, `Connection.protocol_version/0` and the
unreachable clause in `query/3`. Make `close/2` honour `:timeout` instead of
discarding it.

**Files.** `typedb_grpc/lib/typedb/grpc/connection.ex`,
`typedb_grpc/lib/typedb/grpc/transaction.ex`.

**Verify.** The suite stays green; `close/2` with a short timeout returns rather
than waiting `:infinity`.

---

# Refactor plan

| | From | Steps | Status |
| --- | --- | --- | --- |
| [Plan II](#refactor-plan-ii--051) | Audit II, `367a393` | 7 | executed, `4bd648f` … `a09c581` |
| [Plan I](#refactor-plan-i--010-executed) | Audit I, `b96ae98` | 15 | executed, `0e5b005` … `babcbe3` |

---

# Refactor plan II — 0.5.1

Derived from Audit II in `AUDIT.md`, at `367a393`. Ordered by severity, then by
what unblocks what. Every step is atomic: it compiles, the whole suite passes,
and the driver is shippable at the end of it. **One step, one commit.**

## Gate applied after every step

```shell
mix format --check-formatted
mix compile --warnings-as-errors
mix test                                          # 482 unit tests
for a in finch req httpc; do TYPEDB_TEST_ADAPTER=$a mix test; done
mix credo --strict
mix dialyzer
```

Steps touching the transport, an adapter or the wire additionally run against the
live TypeDB 3.12.1 on `:8000`:

```shell
TYPEDB_INTEGRATION_URL=http://127.0.0.1:8000 mix test        # 551
```

Step 7 additionally regenerates and commits `test/api_snapshot.txt`.

**Rollback rule.** If a step breaks the suite and is not fixed within two or
three attempts, it is reverted, marked `blocked` here with the failure, and the
next step proceeds. Steps are ordered so that nothing later depends on anything
earlier except where stated.

---

## Step 1 — Stop losing a good answer to the warning logger (finding A)

**Severity: major. Fixes a bug that turns success into an exception.**

*What changes.* `TypeDB.Log.answer_warning/2` takes the `%TypeDB.Config{}` it
needs instead of a connection it has to look up. Both call sites already hold a
config on the path that produced the answer, so the second ETS read — the one
that raises when the connection is gone — disappears rather than being rescued.

*Files.* `lib/typedb/log.ex`, `lib/typedb.ex` (:278),
`lib/typedb/transaction.ex` (:210), `test/typedb/log_test.exs`.

*How to check.* A new test reproducing the audit's probe: an adapter that holds
the response while the connection is stopped, on an answer carrying a `warning`.
It must return `{:ok, answer}` where today the caller's process dies in
`Connection.lookup!/2`. Verified non-vacuous by reverting the fix and watching it
fail. Public API unchanged — `TypeDB.Log` is `@moduledoc false`.

## Step 2 — Give the httpc adapter the ownership Finch already has (findings B, H)

**Severity: major. Fixes an adapter that stops another application's `:httpc` profile.**

*What changes.* `TypeDB.HTTP.Httpc`'s struct gains `owned?`, set exactly as
Finch sets it: `false` when the caller passed `:profile`, `true` when the adapter
started the profile itself. `terminate/1` stops the profile only when it owns it.
The generated profile name becomes unique per instance
(`:"#{name}.HTTP.#{System.unique_integer([:positive])}"`), matching
`finch.ex:90`, so two connections can never share one by accident.

That is finding H's fix as well: after this the two adapters answer the
ownership question the same way, which matters because they are the worked
examples for anyone implementing `TypeDB.HTTP`.

*Files.* `lib/typedb/http/httpc.ex`, `test/typedb/http_test.exs`.

*Version impact, corrected while executing.* The plan called this a patch. It
is not: `owned?` is a new field on the public `%TypeDB.HTTP.Httpc{}` struct, so
`test/api_snapshot.txt` moves, and under this project's 0.x rule that is a minor.
The field is kept rather than worked around — `TypeDB.HTTP.Finch` has carried
`owned?: boolean()` in the same snapshot since 0.1.x, and making the two adapters
answer the ownership question the same way is finding H itself.

*How to check.* Two tests from the audit's probes: a pre-started profile must
still be alive after `terminate/1`, and a profile the adapter started must be
gone. Plus the existing supervisor-restart test, which already passes and must
keep passing — the profile name change is the risky half of this step. Full
three-adapter matrix and the integration suite, since this changes the transport.

## Step 3 — Reject an `:http` option that does not name an adapter (finding C)

**Severity: major. Restores the documented `:config` contract.**

*What changes.* `TypeDB.Config.parse_http/1` checks that the module is loadable
and exports `init/2`, `request/6` — rejecting `nil`, a module that does not
exist, and a module that is not an adapter — with a `%TypeDB.Error{kind:
:config}` that names the option and the module. `Code.ensure_loaded?/1` is the
check, so a module that exists but is not yet loaded still passes.

`owner/1` and `terminate/1` are deliberately **not** required: both are optional
callbacks and `TypeDB.Connection` already probes them with
`function_exported?/3`.

*Files.* `lib/typedb/config.ex`, `test/typedb/config_test.exs`.

*How to check.* The audit's table becomes three test cases — `{NoSuchAdapter,
[]}`, `{Enum, []}` and `nil` must each be `{:error, %TypeDB.Error{kind:
:config}}` from `Config.new/1`, not `{:error, {:undef, …}}` from `start_link/1`.
A fourth asserts the bare-module form `http: TypeDB.HTTP.Finch` still works, so
the fix does not tighten past what is documented. The three-adapter matrix
covers the regression risk: all three real adapters must still be accepted.

## Step 4 — Replace the forbidden `FunctionClauseError`s (finding D)

**Severity: major. CONTRIBUTING's own rule, applied mechanically.**

*What changes.* Each of the fifteen public functions guarding on `is_binary/1`
gets a fallback clause raising `ArgumentError` that names the argument and what
it must be — the shape `Transaction.open/4` already uses at
`transaction.ex:82` for `:transaction_type`.

To keep this from rotting, the fallbacks are generated from one private helper
rather than hand-written fifteen times, and a test walks the public surface via
`Code.Typespec.fetch_specs/1` — the technique
`test/typedb/api_convention_test.exs` already uses for `!` pairing — asserting
that no public function with a `String.t()` parameter answers a non-binary with
`FunctionClauseError`.

*Files.* `lib/typedb.ex`, `lib/typedb/database.ex`, `lib/typedb/user.ex`,
`lib/typedb/transaction.ex`, `test/typedb/api_convention_test.exs`.

*How to check.* The new convention test is the check, and it fails today. Note
this **changes what these functions raise** — from `FunctionClauseError` to
`ArgumentError`. Under CONTRIBUTING's versioning that is not a covered surface
(neither is in `test/api_snapshot.txt`, and both are exceptions for a value the
caller should not have passed), so it is a patch. Called out here because it is
a behaviour change and the rule says nothing changes without being in the plan.

## Step 5 — Run the Jason codec (finding E)

**Severity: major. A documented extension point with 0% execution coverage.**

*What changes.* Tests only; no `lib/` change. `test/typedb/json_test.exs` gains
a case driving `TypeDB.JSON.Jason` through encode, decode and a decode failure,
and one that configures it as `:json_codec` and runs a real query through the
stub with it — which is the configuration README.md documents.

`:jason` is already resolvable in `dev`/`test` transitively through `:req`.
The step adds it explicitly as `{:jason, "~> 1.4", only: [:dev, :test], runtime:
false}` so the tests do not depend on another package's dependency tree, which
would break silently the day Req drops it.

*Files.* `test/typedb/json_test.exs`, `mix.exs`.

*How to check.* Coverage for `TypeDB.JSON.Jason` goes 0.00% → 100%. The
optional-dependency CI jobs must both still pass: `jason` is `only: [:dev,
:test]`, so a consumer without it is unaffected — and the "Optional dependencies
(none)" job is what proves that.

## Step 6 — Say that the Jason fallback cannot happen (finding G)

**Severity: minor. Dead branch, and two moduledocs describing it as live.**

*What changes.* `TypeDB.JSON.resolve!/0` keeps the `Jason` branch — it costs
nothing and is the correct answer if the Elixir floor ever moves down — but the
moduledocs stop describing it as automatic. `TypeDB.JSON`'s resolution list and
`TypeDB.JSON.Jason`'s "used automatically when `JSON` is unavailable" both say
what is true: on every supported Elixir the built-in codec wins, and `Jason` is
reached by configuring it.

Deliberately *not* deleting the branch: it is unreachable because of a floor, not
because it is wrong, and deleting it would make a future floor change a silent
behaviour change.

*Files.* `lib/typedb/json.ex` (moduledocs only).

*How to check.* `mix docs` clean; the existing `json_test.exs` unchanged and
passing. Documentation-only, so no API impact.

## Step 7 — `:timeout` and `:deadline` on the administrative calls (finding F)

**Severity: minor. NEEDS YOUR DECISION — this one changes the public API.**

*What changes.* All 32 public functions on `TypeDB.Database`, `TypeDB.User` and
`TypeDB.Server` gain a trailing `opts \\ []`, validated by
`TypeDB.CallOptions.request/0` — the same `[:timeout, :deadline]` set the
transaction calls already accept — and forwarded to `Connection.request/4`.

*Why it needs a decision, not just a commit.*

- It rewrites `test/api_snapshot.txt`, which under this project's 0.x rule makes
  it a **minor** version bump, not a patch. Everything else in this plan is a
  patch.
- CONTRIBUTING says the API is meant to be frozen at 1.0 and that `1.0.0` will
  be cut "once the API has survived real use". Widening 32 signatures is the
  opposite direction of travel, and no user has asked for it — I found it by
  reading, not by hitting it.
- The alternative is to do nothing: the connection-level `:timeout` already
  bounds these calls, and the gap is convenience.

**My recommendation was to defer it. You said take all seven, so it was taken.**
The release is therefore 0.6.0 rather than 0.5.2. Nothing is removed and nothing
changes shape — the old arities still exist, generated by the default argument —
so existing calls compile and behave exactly as before.

*Files if taken.* `lib/typedb/database.ex`, `lib/typedb/user.ex`,
`lib/typedb/server.ex`, `lib/typedb/call_options.ex`, `test/api_snapshot.txt`,
`test/typedb/call_options_test.exs`, `CHANGELOG.md`, `mix.exs`.

*How to check.* `call_options_test.exs` already walks `TypeDB` and
`TypeDB.Transaction` asserting that every function taking options validates
them; the three admin modules get added to that walk. Then
`TYPEDB_UPDATE_API_SNAPSHOT=1 mix test test/typedb/api_snapshot_test.exs` and
read the diff before committing it.

---

## Order and dependencies

Steps 1–6 are independent of each other; any can be dropped without affecting
the rest. Step 2 is the one with real regression risk (it renames the httpc
profile), which is why it runs the integration suite and the full adapter matrix
rather than the unit suite alone. Step 7 is last because it is the only one that
moves the version number.

| Step | Finding | Severity | Version impact |
| --- | --- | --- | --- |
| 1 | A | major | patch |
| 2 | B, H | major | **minor** — adds `owned?` to the `TypeDB.HTTP.Httpc` struct, so the API snapshot moves. Found while executing; the plan said patch. |
| 3 | C | major | patch |
| 4 | D | major | patch — but changes which exception is raised |
| 5 | E | major | patch — `:jason` declared `optional: true`, not `only: [:dev, :test]`, which does not resolve |
| 6 | G | minor | patch (docs) |
| 7 | F | minor | **minor** — approved and executed |

After 1–6: `CHANGELOG.md` gets an `Unreleased` entry per step and 0.5.2 is
cuttable.

---

# Refactor plan I — 0.1.0 (executed)

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

## What I needed from you — answered

1. **Step 9** — bang variants: **add them** (option a). Done.
2. **Step 12** — the `:closed` error kind: **drop it**. Done.
3. Nothing was ruled out of scope.

## Outcome

All fifteen steps are complete; none was blocked, none was reverted. Each was committed on its own
after passing the gate. See the "Status after the refactor" section of `AUDIT.md` for the
finding-to-commit mapping and the three judgement calls left open for you.
