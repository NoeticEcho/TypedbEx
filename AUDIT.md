# Audit — TypeDB Elixir driver

Six audits, newest first. Audits I–IV cover `typedb`, Audit V covers
`typedb_grpc`, and Audit VI is the first to sweep both — and the first to audit
efficiency, stability and security as categories of their own.

| | At | Findings | Status |
| --- | --- | --- | --- |
| [Audit VI](#audit-vi--both-packages-at-a4a2e23) | `a4a2e23`, both packages | 8: 0 critical, 4 major, 4 minor | planned, see `REFACTOR_PLAN.md` |
| [Audit V](#audit-v--typedb_grpc) | `3e6b986`, the gRPC package | 9: 2 critical, 3 major, 4 minor | all fixed, `bb08ff1` |
| [Audit IV](#audit-iv--080-through-a-callers-post-mortems) | `447ff97` (0.8.0), through `newgen-elixir`'s own post-mortems | 4 claims tested: 2 held, 2 did not | shipped in 0.8.0 |
| [Audit III](#audit-iii--060-through-a-real-caller) | `41a526b` (0.6.0), through `newgen-elixir` | 2: 1 major, 1 minor | both fixed |
| [Audit II](#audit-ii--051) | `367a393` (0.5.1) | 8: 0 critical, 5 major, 3 minor | all fixed, shipped in 0.6.0 |
| [Audit I](#audit-i--010) | `b96ae98` (0.1.0) | 31: 2 critical, 9 major, 20 minor | all fixed |

Audit I is kept in full, in its original wording, because it records *why*
several things are the way they are — read it before proposing to change one of
them.

---

# Audit VI — both packages, at `a4a2e23`

Audited at `a4a2e23`, after the Rust-parity pass. Two things make this one
different from the five before it. It is the first audit to cover **both**
packages in one sweep, and the first to include **efficiency, stability and
security** as categories of their own — Audits I–V had six categories and none
of them was either.

**Method.** Unchanged, and it is the point: a finding is not a finding until it
has been *run*. Four of the eight below were settled by measuring — the export
cleanup, the item-length ceiling, the streaming buffer and the protocol version
check — and three of those four were invisible to a green suite.

## Stage 1 — what these packages must do

Read from `README.md` (root and both packages), `CLAUDE.md`, both
`CONTRIBUTING.md`, `typedb/guides/*` and this file's Audits I–V. The baseline
every finding below is measured against:

1. **Speak to TypeDB 3.12+ over two transports and mean the same thing.**
   `typedb` over the HTTP API, `typedb_grpc` over gRPC, decoding into the *same*
   `TypeDB.Concept` structs and failing with the *same* `%TypeDB.Error{}`, so
   switching is a line in a data-access module.
2. **Never be the bottleneck.** Requests run in the caller's process; the
   connection process owns only the token and the channel, published through a
   read-concurrent ETS table.
3. **Handle tokens invisibly.** Read the JWT's own lifetime, renew before it
   expires, collapse concurrent renewals into one sign-in, fall back to reactive
   renewal.
4. **Make every failure branchable.** `{:error, %TypeDB.Error{}}` carrying
   TypeDB's stable code, plus a `!` twin that raises — enforced mechanically by
   `api_convention_test.exs` in both packages.
5. **Make parameterised queries safe.** TypeQL's `given` stage in the tagged
   wire form, so a value can never be read as syntax.
6. **Stream what the HTTP API cannot.** No answer cap on gRPC, back-pressured
   reads, and database export/import — a capability the HTTP API does not have
   at all.
7. **Be observable.** `:telemetry` spans for every operation, transaction,
   request and sign-in, with the same event names on both transports and a
   `:transport` tag to tell them apart.
8. **Verify the server, not just talk to it.** TLS on by choice, certificates
   checked against a real trust store, protocol version compared against what
   the generated modules were built from.
9. **Keep the two packages honest about each other.** The shared behaviour suite
   runs one set of assertions through both drivers; a difference is *recorded*,
   never hidden.
10. **Ship nothing unmeasured.** Every performance claim in a README or a
    moduledoc is a number somebody produced against a live server.

## Findings

Nine, against the eight categories. Three major, five minor, no critical — and
one withdrawn during the refactor, by the measurement that should have been
taken before it was written down. See VI-7.

| | Category | Where | Severity |
| --- | --- | --- | --- |
| VI-1 | Requirement mismatch | `typedb_grpc/lib/typedb/grpc/transaction.ex:57` | minor |
| VI-2 | Errors | `typedb_grpc/lib/typedb/grpc/database.ex:230` | major |
| VI-3 | Errors | `typedb_grpc/lib/typedb/grpc/database.ex:246` | major |
| VI-4 | Gaps | `typedb_grpc/lib/typedb/grpc/migration.ex:76` | major |
| VI-5 | Gaps | `typedb_grpc/lib/typedb/grpc/transaction.ex:290` | minor |
| VI-6 | Quality | `typedb_grpc/lib/typedb/grpc/transaction.ex:1103` | minor |
| VI-7 | Efficiency | `typedb_grpc/lib/typedb/grpc/transaction.ex:900` | **withdrawn** |
| VI-8 | Security | `typedb_grpc/lib/typedb/grpc/config.ex:111` | minor |
| VI-9 | Requirement mismatch | `AUDIT.md:11` | minor |

### 1. Requirement mismatch

#### VI-1 — the transaction moduledoc denies a feature the module has (minor)

`typedb_grpc/lib/typedb/grpc/transaction.ex:57`

> The current API collects the parts before returning, so a very large answer is
> a very large list. Constant-memory streaming is a further step and not done.

`stream/3` is eighty lines below it, `TypeDB.GRPC.stream/4` wraps it, both
READMEs lead with it and the streaming suite measures it. The sentence was true
when it was written and has been false since the streaming step landed. A
moduledoc that denies the module's headline feature is worse than no moduledoc:
it is the first thing a reader believes.

#### VI-9 — this document's index links to an audit it does not contain (minor)

`AUDIT.md:11`

The table of audits links Audit IV to `#audit-iv--080-through-a-callers-post-mortems`.
There is no such heading: `AUDIT.md` contains Audits I, II, III and V and has
never contained IV. Its findings were real — they are the substance of `typedb`
0.8.0 and are described in that release's CHANGELOG entry — but the document
that claims to record them does not.

Found while writing this audit, which is the only way a dead anchor in a
document nobody links to gets found.

### 2. Errors

#### VI-2 — a failed export leaves a file it opened and never closes (major)

`typedb_grpc/lib/typedb/grpc/database.ex:230`, `write_export/3`

```elixir
with {:ok, schema_file} <- open_write(schema_path),
     {:ok, data_file} <- open_write(data_path) do
```

When the *second* `open_write/1` fails, `with` short-circuits: the schema file
is neither closed nor removed, and `discard_files_on_failure/3` — the function
whose whole job is to make sure a failed export leaves nothing behind — is never
reached.

**Measured**, against a live 3.12.1, exporting to a data path whose directory
does not exist:

```
result: {:error, %TypeDB.Error{kind: :config, reason: :enoent, ...}}
schema file left on disk: true
```

The module's own documentation promises the opposite in as many words: "both are
removed again if the export fails part-way — a half-written backup that looks
like a backup is worse than none". Here it is worse still: an *empty* file that
looks like a backup.

#### VI-3 — a write failure does not stop the export (major)

`typedb_grpc/lib/typedb/grpc/database.ex:246`, `drain_export/3`

```elixir
{:schema, schema} -> {:cont, write(schema_file, schema, acc)}
{:items, items}   -> {:cont, write(data_file, ..., acc)}
```

`write/3` returns `{:error, _}` when `:file.write/2` fails — a full disk, a
revoked permission — and the reduce **continues**. The error survives to the end
(a later successful write returns the accumulator unchanged), so the caller is
told the truth eventually; but between the failure and the truth the driver
drains the entire remaining export from the server and keeps trying to write
every part of it. On the graph this feature exists for, that is minutes of
network and CPU spent on an outcome already decided.

### 3. Gaps

#### VI-4 — a corrupt data file is read into memory before it is rejected (major)

`typedb_grpc/lib/typedb/grpc/migration.ex:76`, `take_items/2`

```elixir
{:ok, length, rest} when byte_size(rest) >= length ->
```

Nothing bounds `length`. A delimiter declaring an item larger than the rest of
the file simply never satisfies the guard, so the reader keeps pulling 64 KiB
chunks and appending them to the buffer until EOF, and only *then* raises "the
data file ends mid-item". The memory ceiling is the size of the file.

**Measured**: a file whose first varint declares 256 MiB, followed by 5 MB of
zeroes, is buffered whole — the error reports `5000005 bytes left over`. At 5 MB
that is nothing; the same shape at 5 GB is an out-of-memory kill of the node,
caused by a file the operator was told was a backup. Nothing about the size of
the declared length matters, only that it exceeds what follows it: the buffer
grows to the file, whatever the delimiter said.

TypeDB's own items are entities, attributes and relations — kilobytes. A
declared length beyond any plausible item is not a truncated file, it is not a
TypeDB export, and it can be refused on the first chunk instead of the last.

#### VI-5 — an abandoned streamed read is never collected (minor)

`typedb_grpc/lib/typedb/grpc/transaction.ex:290`, `do_stream_next/3`

A `stream_next` that times out abandons its request — deliberately, and Audit V
records why. What it leaves behind is the accumulator in `state.pending`, keyed
by a `req_id` nobody will ask about again, holding whatever rows had arrived.
The comment says it is "collected when the transaction ends", which is true and
is the whole of the cleanup. A long-lived transaction whose consumer times out
repeatedly grows that map without bound.

Minor because a transaction is short by construction and the server's own
`transaction_timeout_millis` ends it anyway.

### 4. Incomplete work

**Nothing.** No `TODO`, `FIXME`, `HACK` or `XXX` anywhere in either `lib/`, no
stub, no mock data, no hardcoded value that wants configuring. Checked
mechanically; the same was true at Audit V and is now true of both packages.

### 5. Empty functions

**Nothing, and structurally so.** Both packages compile with
`--warnings-as-errors`, and an unused private function is a warning — so dead
private code cannot survive a build. The public surface of both is enumerated by
`api_snapshot.txt` and `api_convention_test.exs`, which fail on an addition
nobody declared.

### 6. Code quality

#### VI-6 — "pipelining" sends one message per request (minor)

`typedb_grpc/lib/typedb/grpc/transaction.ex:1103`, `send_reqs/2`

```elixir
Enum.each(reqs, fn req ->
  GRPC.Stub.send_request(state.stream, %Proto.Transaction.Client{reqs: [req]})
end)
```

`Transaction.Client` carries `repeated Req reqs` and the moduledoc explains the
pipelining in terms of that repeated field. The code does not use it: two
hundred pipelined reads are two hundred `Transaction.Client` messages of one
request each. The win the moduledoc measures is real and comes from not waiting
for each reply — but it is not the win the code comment describes, and the frame
overhead is paid per request rather than per batch.

Either batch them or correct the explanation; the audit's position is that the
explanation is the thing that must not be wrong.

### 7. Efficiency and stability

#### VI-7 — WITHDRAWN: the streamed-read buffer is not quadratic in practice

`typedb_grpc/lib/typedb/grpc/transaction.ex:900`, `on_part/3`

**The finding as written was wrong, and the way it was wrong is worth keeping.**

What was observed is real: reading 20 000 rows through `TypeDB.GRPC.stream/4`
takes 477 ms at the default prefetch and 838 ms with `prefetch_size: 20_000`.
What was *asserted* — that the cause is `acc.buffer ++ …` copying the buffer on
every part — was reasoned from the code and never measured. It is false.

Instrumenting `on_part/3` to count parts and the buffer length at each append:

| `prefetch_size` | parts | rows | longest buffer at append | time |
| --- | ---: | ---: | ---: | ---: |
| default | 626 | 20 000 | **0** | 432 ms |
| 20 000 | **2** | 20 000 | **0** | 985 ms |

The buffer is empty every single time a part arrives, so `++` never copies
anything: its left operand is always `[]`. That is not luck, it is the
back-pressure design — a part only arrives because a consumer asked for one, and
`serve_stream/3` hands it over the moment it lands. And the slow case is the one
with *two* parts, which no quadratic can explain.

The real cause is the server. `prefetch_size: 20_000` tells it to produce
twenty thousand answers before sending anything, so it sends two parts of ten
thousand, and the driver's decoding no longer overlaps with the server's work
the way it does across 626 small parts. Nothing in the driver is at fault, and
the fix drafted for it — prepend and reverse on serve — was written, measured to
change nothing (913 ms against 838 ms, noise), and reverted.

What survives is a fact worth telling users, and it is now in
`Transaction.query/3`'s documentation: raising `:prefetch_size` makes a streamed
read **slower**, not faster.

This is the audit's own method failing and then catching itself. A finding
reasoned from code is a hypothesis; it is worth exactly as much as the
measurement that follows it.

Also examined and clean: `build_answer/1` already prepends and reverses;
`Migration.items/1` streams in bounded chunks; the transaction's reader process
is linked, so a dead stream takes the transaction with it rather than leaking;
`Connection.terminate/2` disconnects the channel. One inefficiency is recorded
and left alone: several ETS lookups per call (`config/1` inside `timeout/2`, plus
`channel/1`) where one would do — it is a read-concurrent table and the cost is
not measurable next to a round trip.

### 8. Security

#### VI-8 — a remote gRPC connection is plaintext by default and says nothing (minor)

`typedb_grpc/lib/typedb/grpc/config.ex:111`, `tls: false`

The default matches TypeDB CE, which ships with encryption off, and for a server
on loopback — the deployment this driver was written for — it is right. For a
server anywhere else it means the username and password cross the network in the
clear, and nothing in the driver says so. Rust does not have this problem
because `DriverOptions::new/1` takes the TLS configuration as a *required*
argument: there is no default to fall into.

Changing the default would break every working configuration for the common
case, which is a poor trade. Saying it out loud when the address is not loopback
costs one log line.

#### Checked and clean

* **No credential reaches a log, a telemetry event or an error.** The config
  published to ETS is redacted (`Connection.redact/1`), both `Inspect`
  implementations omit password and token, `TypeDB.Log` is the single Logger
  entry point and logs neither, and `TypeDB.GRPC.Error` reads only
  `ErrorInfo.reason` and `DebugInfo.stack_entries` out of a failure — never
  metadata, which is where the bearer token is.
* **Injection.** Database and user names are percent-encoded per path segment on
  HTTP (`TypeDB.Wire.path_segment/1`) and are protobuf fields on gRPC, where
  there is no text to inject into. Query values go through `given` rather than
  interpolation, which is the feature that makes that true.
* **TLS verification is on and cannot be turned off by accident.** `verify_none`
  is an explicit option, and the TLS suite asserts that a certificate signed by
  an untrusted CA is refused — an assertion that would fail if the default ever
  weakened.
* **Dependencies.** `typedb` is fully current. In `typedb_grpc`, `gun` (2.4.1 →
  2.5.0) and `googleapis` (0.1.0 → 0.2.0) are behind, both held there by `grpc`
  and `grpc_core`'s own requirements rather than by ours — `mix.exs` already
  allows the newer ones. Nothing to do here; it moves when `grpc` moves.

## Verified, not findings

* **The server really does check the protocol version at `connection_open`.**
  The claim was added to `Server.check_protocol/2`'s documentation during the
  parity pass and had not been measured. It is true: sending
  `version: :UNSPECIFIED` to 3.12.1 is refused with *"Incompatible driver
  version. This 'elixir' driver…"* — the server even names the `driver_lang`
  this driver sends.
* **`create_if_not_exists/3` has a TOCTOU race and it is harmless.** Two callers
  can both see "absent" and both create; `databases_create` is a no-op for an
  existing database on both transports, which the shared suite asserts.
* **Retrying an unauthenticated streaming import is safe.** `Connection.unary/4`
  retries once on `:unauthenticated`, which for `import_from_files/5` means
  re-sending the file. The rejection arrives on the first message, before the
  server has created anything, so the retry starts from nothing.

---

# Audit V — `typedb_grpc`

Audited at `3e6b986`. The package was written in a single session, reached
feature parity with its sibling quickly, and had never been read back. That is
the profile of code that is worth auditing: `typedb` has had four passes and is
at 0.8.0, while this had none.

**Method.** The three findings that matter were settled by running rather than
by reading — the same rule the rest of this document is held to. The rest are
mechanical and are marked as such.

## Несоответствие задаче

**V-1. `datetime-tz` decodes to a different type than the sibling, and to the
wrong instant.** `lib/typedb/grpc/decode.ex`, `datetime_tz/2`. **critical.**

Measured against 3.12.1, inserting `2024-03-01T12:00:00.000+05:00` and reading
it back:

| | value | unix |
| --- | --- | --- |
| `typedb` | `%TypeDB.DateTimeTZ{naive: ~N[2024-03-01 12:00:00.000000], utc_offset: 18000}` | — |
| `typedb_grpc` | `#DateTime<2024-03-01 07:00:00.000000+05:00>` | 1709258400 |
| correct | | 1709276400 |

Two defects in one function. The type is wrong — the sibling has a dedicated
`TypeDB.DateTimeTZ` struct precisely because a `DateTime` cannot hold "this wall
clock, in this zone" without a tz database — and the instant is five hours out,
because the decoder stamps the offset onto a UTC `DateTime` without shifting the
wall clock.

This is the worst kind of defect this package can have: it returns a plausible
answer that is silently wrong, and the shared behaviour suite did not catch it
because it has no temporal-type coverage. See V-9.

**V-2. Thirty public functions return `{:error, %TypeDB.Error{}}` and two have a
`!` twin.** All of `lib/typedb/grpc/`. **major.**

`CLAUDE.md` states the convention — "every failing operation returns
`{:error, %TypeDB.Error{}}` and has a `!` twin that raises" — and `typedb`
enforces it mechanically in `test/typedb/api_convention_test.exs`. This package
has `TypeDB.GRPC.query!/4` and `Config.new!/1` and nothing else, so an
application that switches transports loses every `!` call it wrote.

## Ошибки

**V-3. Two processes sharing one transaction handle lose one of them.**
`lib/typedb/grpc/transaction.ex`, the `awaiting` field. **critical, race
condition.**

The state holds *one* outstanding call: `%{state | awaiting: {from, ids, %{}}}`
overwrites whatever was there. The moduledoc promises the opposite — "the handle
you hold is still a plain struct, so it can still be passed between processes
freely, which is the property the sibling driver documents and which would
otherwise have been lost".

Measured, two `Task`s querying one handle:

```
caller 1: ERROR :timeout the transaction did not answer within 8000ms; it has been closed
caller 2: ok, 1 rows
```

The first caller's `from` is discarded, it waits out its timeout, and the
timeout path then closes the transaction — so the loser also destroys the
winner's transaction.

**V-4. `Config.from_url/1` decides the port by substring.** `config.ex`,
`grpc_port/2`. **major.**

`URI.parse` fills in a scheme's default port, so 80 and 443 have to be told from
"the caller wrote no port". The test is `String.contains?(url, ":80")`, which
matches anywhere in the string — a path segment, an IPv6 host, userinfo. The
same function also calls `URI.parse/1` twice on the same input.

## Gaps

**V-5. The stream-batch telemetry event carries `connection: nil`.**
`transaction.ex:233`, a literal. **major.**

`TypeDB.GRPC.Telemetry`'s doc says the event's metadata is `:transport` and
`:connection`. The transaction struct never carried the connection name, so the
call site fills in `nil` rather than the doc being corrected — a metric grouped
by connection silently collapses to one series.

**V-9. The shared behaviour suite has no temporal-type coverage.**
`test/behaviour/shared_behaviour_test.exs`. **minor, but it is why V-1
survived.**

The suite compares strings, integers, doubles and `date`. `datetime`,
`datetime-tz` and `duration` are exactly where two independent decoders drift,
and they are the ones it does not look at.

## Пустые функции

**V-6. `Connection.lifetime_margin/1` takes a parameter it ignores and returns a
constant.** `connection.ex:389`. **minor.**

**V-7. `Connection.protocol_version/0` is unreachable indirection.**
`connection.ex:416` — `@doc false`, nothing calls it, and it forwards to
`TypeDB.GRPC.Protocol.version/0` which is public. **minor.**

**V-8. A dead clause in `Transaction.query/3`.** `{:ok, answers} ->
{:ok, List.last(answers)}` cannot be reached: the call above it always passes a
one-element list. **minor.**

## Качество

**V-10. `Transaction.close/2` accepts `_opts` and ignores it.**
`transaction.ex:293`. The sibling's `close/2` takes `:timeout` and `:deadline`
and uses them. Here the parameter exists only so the signatures match, which is
worse than not having it: a caller passing a timeout gets no error and no
timeout. **minor.**

## Outcome

All nine fixed, in six commits, each with the gate run and each with its test
proven non-vacuous by reintroducing the defect:

| step | findings | commit |
| --- | --- | --- |
| 1 | V-1, V-9 — `datetime-tz` type and instant, temporal coverage | `1afaf1d` |
| 2 | V-3 — concurrent callers on one transaction | `e22e95e` |
| 3, 4 | V-5 `connection: nil`, V-4 the port heuristic | `315ee77` |
| 5 | V-2 — twenty-five `!` twins and a convention test | `5d3b11a` |
| 6 | V-6, V-7, V-8, V-10 — dead code, `close/2`'s options | `bb08ff1` |

Nothing was blocked and nothing was rolled back. Two things are worth carrying
forward rather than forgetting:

**The two critical findings were both invisible to the suite that existed.**
V-1 survived because the shared behaviour suite compared strings, integers and
dates but not temporal types; V-3 survived because every test used a
transaction from one process. Both suites were green throughout. That is the
argument for auditing code that passes its tests.

**The `!` twins were missing because nothing checked.** The convention has been
written in `CLAUDE.md` since before this package existed and enforced in the
sibling since 0.1.0; the new package simply never had the test, and thirty
functions drifted in one session. The test now exists here too.

## Not findings

Checked and deliberately not listed:

  * **No TODO, FIXME or stub anywhere in `lib/`.** The generated protocol
    modules are machine-written but they are not stubs, and CI regenerates and
    diffs them.
  * **No mock data or hardcoded credentials.** The only literal that looked
    like configuration — the answer-batch size — turns out not to exist here at
    all, because this transport has no answer cap to configure.
  * **`typedb` itself.** Four audits and 508 tests; the only change to it this
    session was additive telemetry metadata, covered by its own suite.

---

# Audit III — 0.6.0, through a real caller

Audited at `41a526b`, against **`NoeticEcho/newgen-elixir`** at `17e6b20` — a
twelve-application umbrella that uses this driver in `apps/lingua_nkr` and pins
`{:typedb, "~> 0.3"}`.

**Why this audit is not a third read-through of `lib/`.** Audit I found 31
things, Audit II found 8; a third pass over the same code with the same eyes
would find fewer still. What changed is that the driver now has a real caller,
which is the one thing neither earlier audit could consult. So the method here
is different: read how the driver is actually used, run the application's own
suite against the current driver, and treat every workaround the application
had to write as evidence of something the driver did not give it.

## What was verified

The headline is a compatibility claim I made when cutting 0.6.0 and had not
tested against anyone: *nothing is removed and nothing changes shape, so
existing code compiles and behaves as before.*

| | |
| --- | --- |
| the umbrella compiles against 0.6.0, pinned at `~> 0.3` | ✅ all twelve applications |
| `apps/lingua_nkr` graph suite against a live TypeDB 3.12.1 | ✅ **31/31** |
| and that suite is not vacuous | ✅ pointed at a dead port: **0 tests, 31 invalid** |

The claim holds. It is now tested rather than asserted.

## Findings

### R1 — There is no way to ask whether a connection is usable, so the caller invented a broken one
`lib/typedb/connection.ex:109`; used at `newgen-elixir` `apps/lingua_nkr/lib/lingua/nkr/client.ex:28`
**Category: gap — a missing affordance, with a real casualty. Severity: major.**

A call against a connection that is not running **raises** `%TypeDB.Error{kind:
:config}` rather than returning it. Audit II settled that deliberately: a name
that is not running is nearly always a typo, and it is what the ecosystem does.

Here is what it costs a real application. It cannot let the raise happen — it
maps driver failures onto its own error taxonomy — so it built a predicate:

```elixir
def connected?, do: is_pid(Process.whereis(@conn))
```

and guards **six** public functions with it. The driver offers nothing better,
so the application reached into the process registry.

**The guard does not work.** `GenServer.start_link(name: ...)` registers the
name before `init/1` returns, so the pid exists before the ETS table the driver
reads does. Reproduced with an adapter whose `init/2` takes 150ms:

```
app's predicate says connected?: true
...and the very next call:        {:raised, :config, "TypeDB connection ... is not running."}
```

This is not the application being careless — the driver's own
`connection_test.exs` records the same race ("a fresh pid under the name does
not yet mean a connection with a config table … Seen as a CI-only failure").
The driver knows the fact and keeps it private, and the caller could only guess.

The fix is small and does not reopen the raise-or-return decision: a public
predicate that answers what `Connection.config/1` would do, without doing it.

### R2 — `create_if_not_exists` is invisible from the facade the application uses
`lib/typedb.ex` convenience delegates; `apps/lingua_nkr/lib/lingua/nkr/client.ex:79`
**Category: quality — discoverability. Severity: minor.**

`TypeDB` delegates `databases/2`, `create_database/3`, `delete_database/3`,
`health/2` and `version/2`. It does **not** delegate
`Database.create_if_not_exists/3`. An application that works through the facade
— as this one does, exclusively — does not meet that function, and this one
reimplemented it:

```elixir
case TypeDB.databases(@conn) do
  {:ok, databases} -> if name in databases, do: :ok, else: create_database(name)
```

Two round trips instead of one, and a list of every database on the server to
answer a question about one. The reimplementation is *correct* — `create` is
idempotent on TypeDB 3.x, so the race is benign — which is exactly why nobody
would notice it was unnecessary.

## Status

Both findings are fixed, and — because this audit had a real caller — the fixes
were checked in the place the problem was found. `apps/lingua_nkr/client.ex` was
rewritten onto `TypeDB.running?/1` and
`TypeDB.create_database_if_not_exists/3`, deleting its `Process.whereis` guard
and its list-then-check, and the application's 31 graph tests still pass against
a live TypeDB. That edit was made in a scratch clone and not pushed; it is the
patch the application would apply, offered as evidence rather than as a change
to somebody else's repository.

R1's test is the one worth keeping honest: it holds an adapter's `init/2` open,
asserts that `Process.whereis/1` already answers true, and that `running?/1`
does not. Substituting the application's own implementation fails it.

## Not a driver defect, but worth saying

`apps/lingua_nkr/mix.exs` pins `{:typedb, "~> 0.3"}`, which means
`>= 0.3.0 and < 1.0.0`. This driver's own CONTRIBUTING says that in `0.x` a
**minor** carries anything a `1.x` would call breaking — so that requirement
admits every breaking release between here and 1.0, silently. The README's
install snippet shows the form that does not: `{:typedb, "~> 0.6.0"}`, which is
`>= 0.6.0 and < 0.7.0`. 0.6.0 happens to be compatible, as the suite above
proves; the next minor is under no obligation to be.


# Audit II — 0.5.1

Audited at `367a393` (main), the 0.5.1 release commit. This is the second audit of
this driver; the first, at `b96ae98`, is below in the same file and all 31 of its
findings were fixed.

**Method.** The reference below was rebuilt from README.md, CONTRIBUTING.md,
CLAUDE.md and the moduledocs, then the whole of `lib/` was read against it.
Nothing here is a reading of the code alone: **every finding was reproduced by
running it**, and the reproduction is quoted under the finding. Three hypotheses
that looked like findings on the page did *not* reproduce and are recorded under
[Not findings](#not-findings) so nobody spends the afternoon on them again.

**Scale.** 6,134 lines under `lib/`, 482 unit tests × 3 HTTP adapters, 551 with
integration, 88.05% line coverage. Eight findings: 0 critical, 5 major, 3 minor.
That is a lower yield than Audit I's 31, which is what a second audit of a
codebase that took the first one seriously should look like.

## Reference: what the driver must do

1. Connect to TypeDB 3.12+ over HTTP API v1; config is URL plus username/password
   or a pre-issued token; supervised; several named connections at once.
2. Auth: lazy sign-in, proactive renewal from the JWT's own lifetime, reactive
   renewal on `401` bounded by `:max_auth_renewals`, concurrent renewals
   collapsed into one sign-in, credentials never published.
3. Full API v1 coverage: signin, health, version, servers, databases, users,
   transactions, one-shot `/query`, analyze.
4. Requests run in the caller's process; the connection process is not a
   throughput bottleneck.
5. Answers decode into `Ok` / `ConceptRows` / `ConceptDocuments`; concepts into
   structs; rows implement `Access`; answers implement `Enumerable`; values
   convert to native Elixir terms.
6. `given_rows` are encoded in TypeDB's tagged wire form, so no input can be
   parsed as TypeQL.
7. Every failure is a `%TypeDB.Error{}` with a `:kind` and TypeDB's stable
   `:code`; every fallible operation has a `!` twin; CONTRIBUTING's "return or
   raise" rule is followed, including its ban on a bare `FunctionClauseError`
   from a public function.
8. Pluggable transport: Finch default, Req and httpc alternatives, TLS verified
   by default in all three, and the choice invisible to the caller.
9. Pluggable JSON codec; telemetry spans for requests, transactions and sign-ins.
10. `TypeDB.transaction/5` commits on success, rolls back on error, raise, throw
    or exit, and closes a `:read`.

---

## Major

### A — A successful answer can be destroyed by the code that logs its warning
`lib/typedb/log.ex:37`, reached from `lib/typedb.ex:278` and `lib/typedb/transaction.ex:210`
**Category: bug.**

`Log.answer_warning/2` runs after the answer is decoded, and looks the connection
up again to find its `:log_level`:

```elixir
log(TypeDB.Connection.config(conn), :warning, ...)
```

`Connection.config/1` reads the connection's ETS table and **raises** when it is
gone (`connection.ex:109`). So when the connection dies between the response
arriving and the warning being logged, a query that fully succeeded raises
instead of returning `{:ok, answer}`.

Reproduced with an adapter that holds the response while the connection is
stopped, on an answer carrying a `warning` — the caller's process died with:

```
(stdlib) :ets.lookup(:warn_race, :config)
(typedb) lib/typedb/connection.ex:109: TypeDB.Connection.lookup!/2
(typedb) lib/typedb/log.ex:37: TypeDB.Log.answer_warning/2
```

The trigger is narrow — the connection must go away mid-request *and* the answer
must carry a warning — but both halves are ordinary: a supervisor restarting the
connection during a deploy, and a read TypeDB truncated at 10,000 rows. Logging
must not be able to turn a success into an exception, and the config it needs is
already in hand at both call sites.

### B — The httpc adapter stops an `:httpc` profile it did not start
`lib/typedb/http/httpc.ex:88`, with `:76` and `:179`
**Category: bug — resource lifecycle.**

`TypeDB.HTTP.Finch` tracks `owned?` (`finch.ex:77`, `:139`) precisely so that an
adapter handed an existing instance neither owns nor stops it — that was finding
m3 of Audit I. The httpc adapter has no such notion. `start_profile/1` treats
`{:error, {:already_started, _pid}}` as success, and `terminate/1` stops the
profile unconditionally.

Reproduced:

```
A. before adapter init, profile manager: #PID<0.202.0>
A. after adapter terminate,   profile manager: nil
   ^ nil means the adapter stopped a profile it did not start
```

`:profile` is a documented option. An application that runs its own `:httpc`
profile and points a TypeDB connection at it — to share sockets, or because the
profile carries proxy settings — loses that profile when the connection stops,
and the breakage lands somewhere else entirely.

The second half of the same gap: the profile name is `:"#{name}.HTTP"`, derived
from the *connection* name rather than being unique per instance the way Finch's
pool name is (`finch.ex:90`). Two connections pointed at one profile share it,
and the first to terminate takes the other's transport down — reproduced, the
survivor's profile manager was `nil`.

### C — `:http` is the one option naming code, and it is not checked
`lib/typedb/config.ex:492-500`, surfacing at `lib/typedb/connection.ex:294`
**Category: gap — missing validation.**

`parse_http/1` accepts any atom as an adapter module. `TypeDB.Config` exists to
reject bad configuration at start-up — its own comment for `parse_timeout/3`
explains why, having watched a string from `System.get_env/1` boot "a green
application that then failed every single request, deep inside the HTTP adapter".
`:http` is the option most able to do exactly that, and it is unchecked.

Reproduced:

| `:http` | `Config.new/1` | `TypeDB.start_link/1` |
| --- | --- | --- |
| `{NoSuchAdapter, []}` | `{:ok, config}` | `{:error, {:undef, …}}` |
| `{Enum, []}` | `{:ok, config}` | `{:error, {:undef, …}}` |
| `nil` | `{:ok, config}`, `http_adapter: nil` | `{:error, {:undef, …}}` |

`nil` passes because `nil` is an atom. All three break the contract stated in
README.md:416 and `guides/errors-and-retries.md` — that a misconfigured
connection is `%TypeDB.Error{kind: :config}` — and `{:error, {:undef, …}}` names
neither the option nor the module.

`init_adapter/1` (`connection.ex:294`) calls `adapter.init/2` bare, outside the
`Transport.contain/3` that guards every other adapter call, so there is no second
line of defence either.

### D — A non-binary name or query raises a bare `FunctionClauseError`
`lib/typedb.ex:248`, `lib/typedb/database.ex:45,70,87,112,140,160,168`,
`lib/typedb/user.ex:45,82,106,128`, `lib/typedb/transaction.ex:82,192,240`
**Category: gap — CONTRIBUTING violated mechanically.**

Fifteen public functions guard on `is_binary/1` with no clause for anything else.
CONTRIBUTING.md:147 forbids this in as many words:

> **Never a bare `FunctionClauseError` from a public function** for a value a
> caller could plausibly pass. […] Add a clause that raises `ArgumentError` with
> the accepted values.

Reproduced, five of the fifteen:

```
TypeDB.query/4 database: nil        no function clause matching in TypeDB.query/4
Database.create/2 name: :social     no function clause matching in TypeDB.Database.create/2
Database.delete/2 name: nil         no function clause matching in TypeDB.Database.delete/2
User.create/3 username: nil         no function clause matching in TypeDB.User.create/3
Transaction.open/4 database: :d     no function clause matching in TypeDB.Transaction.open/4
```

A database name is the single most likely thing to arrive from configuration as
`nil` or as an atom. `Transaction.open/4` shows the intended shape one line
away: `transaction.ex:82` already has a clause that raises `ArgumentError`
naming the three valid transaction types — but only when the database is
already a binary.

### E — `TypeDB.JSON.Jason` is documented, shipped, and never executed
`lib/typedb/json.ex`, `TypeDB.JSON.Jason`
**Category: gap — untested public extension point.**

Coverage: **0.00%**. No test in the suite calls it, and `:jason` is present in
`deps/` (transitively, through `req`), so the absence is not a missing
dependency — nothing was ever written.

README.md documents `config :typedb, :json_codec, TypeDB.JSON.Jason` as a
supported configuration. The codec does work — checked by hand:

```
Jason codec encode:       {"a":[1,true,null]}
Jason codec decode:       {:ok, %{"a" => [1, true, nil]}}
Jason codec on bad input: {:error, %Jason.DecodeError{position: 1, ...}}
```

So this is a gap rather than a defect today. It is the same shape as the bug in
`guides/testing.md` that Audit I's `TypeDB.GuideTest` was written for: published
code that nothing runs is published code nobody has checked.

---

## Minor

### F — Administrative calls cannot be given a timeout
`lib/typedb/database.ex`, `lib/typedb/user.ex`, `lib/typedb/server.ex` — 32 public functions
**Category: gap — missing functionality.**

Not one of `TypeDB.Database.*`, `TypeDB.User.*` or `TypeDB.Server.*` accepts
options, so none can take `:timeout` or `:deadline`. Every one of them makes an
HTTP request.

The documentation is careful — `guides/errors-and-retries.md` says both are
per call "on every function that takes `:timeout`" — so nothing here is *false*.
But `Database.schema/2` on a large schema, and `Server.health/1` used as a
readiness probe that should give up in 500ms, are exactly the calls that want
their own budget, and they are stuck with the connection default.

Filed as minor because it is missing convenience rather than broken behaviour.
It is the one finding in this audit whose fix **changes the public API**
(32 new optional arguments, a new `test/api_snapshot.txt`, a minor version under
this project's 0.x rule), so it needs a decision rather than a patch.

### G — The Jason fallback branch cannot execute on any supported Elixir
`lib/typedb/json.ex:72`
**Category: dead code + documentation contradicting it.**

```elixir
Code.ensure_loaded?(JSON)  -> TypeDB.JSON.Native
Code.ensure_loaded?(Jason) -> TypeDB.JSON.Jason   # unreachable
```

`mix.exs:11` declares `elixir: "~> 1.18"`, and the built-in `JSON` module exists
on every Elixir from 1.18. The clause above it therefore always matches, so the
`Jason` branch — and the `raise` below it — are unreachable by construction.

Both moduledocs describe the unreachable path as if it happens: `TypeDB.JSON`
lists it as resolution step 3, and `TypeDB.JSON.Jason` says it is "used
automatically when `JSON` is unavailable". `Jason` is reachable only by
configuring it explicitly, which is worth saying plainly.

### H — Two adapters express the same lifecycle two different ways
`lib/typedb/http/finch.ex:56,77,135,139` against `lib/typedb/http/httpc.ex:70,85,88`
**Category: quality — inconsistent pattern between modules.**

The root of finding B, recorded separately because the fix is a shape, not a
patch. For the same three questions the two shipped adapters answer differently:

| | Finch | httpc |
| --- | --- | --- |
| instance name | unique per instance (`.Finch.<int>`) | derived from the connection name |
| ownership | tracked in `owned?`, honoured by `terminate/1` | not represented |
| `owner/1` | the supervisor pid, so the connection links to it | always `nil` |

`TypeDB.HTTP` is a public behaviour, so these two are also the worked examples
anyone writing a third adapter will copy. They should not disagree about what
`terminate/1` is allowed to stop.

---

## Not findings

Reproduced as *working*, and recorded so they are not re-raised:

- **A supervisor-restarted httpc connection recovers.** This was the obvious
  corollary of finding B — the Finch pool name was made unique per instance in
  Audit I (C1) for exactly this reason. It does not reproduce for httpc: three
  consecutive kill-and-restart rounds all answered `:ok`, because `terminate/2`
  stops the profile before `init/1` starts it again.
- **The `TypeDB.Duration` component scanner is faithful.** The hand-written
  scanner that replaced a regex for speed was differentially tested over 200,000
  generated inputs: `from_iso8601 -> to_iso8601 -> from_iso8601` disagreed **0**
  times.
- **Answer warnings are logged on both query paths.** One-shot `TypeDB.query/4`
  and `TypeDB.Transaction.query/3` both funnel through `Log.answer_warning/2`,
  so a truncated answer is never silent inside an explicit transaction either.

Also checked and clean: no `TODO`, `FIXME`, `HACK` or `XXX` anywhere in `lib/`
or `test/`; no stubs, mock data or hardcoded values that should be configurable;
no dead private functions (`--warnings-as-errors` makes them impossible); no
duplicated helper left after Audit I moved them into `TypeDB.Wire` and
`TypeDB.Bang`. `http: TypeDB.HTTP.Finch` as a bare module is accepted
deliberately and resolves correctly to `{TypeDB.HTTP.Finch, []}` — that one
looked like a silent fallback and is not.

---

## Status after the refactor

Executed as `REFACTOR_PLAN.md`'s Plan II sequenced it, in seven commits from
`4bd648f` to `a09c581`. **All eight findings are fixed.**

Every step ran the same gate before being committed: `mix format
--check-formatted`, `mix compile --warnings-as-errors`, `mix test` under all
three HTTP adapters, `mix credo --strict`, `mix dialyzer`, and the integration
suite against a live TypeDB 3.12.1. Final state: **496 unit tests × 3 adapters,
565 with integration** (from 489 and 558), credo clean, dialyzer clean, docs
clean.

Each fix was verified by **deliberately reintroducing the defect and watching the
new test fail**, which is recorded per row below.

### Fixed

| Finding | Commit | What changed | Proved by |
| --- | --- | --- | --- |
| A | `4bd648f` | `Log.answer_warning/2` takes the config instead of looking the connection up after the answer is already in hand. One ETS read per query where there were two. | Reverting it fails 4 of the 5 new tests with the original error. |
| B, H | `72261c5` | `TypeDB.HTTP.Httpc` grows `owned?` and honours it, and names its profile per instance as Finch already does. The two adapters now answer the ownership question identically. | Reverting it fails 3 tests, one on the exact assertion message. Supervisor-restart recovery checked before and after. |
| C | `86edb0d` | `:http` must name a loadable module exporting the behaviour's two mandatory callbacks. | Reverting it fails 2 tests. A third asserts all three shipped adapters, plus a minimal one, still pass. |
| D | `b4bae7e` | Fifteen `is_binary/1` guards become `Wire.string!/2`, one helper so the message cannot drift. | A spec-derived test builds 29 probes; 20 raised `FunctionClauseError` before, 0 after. |
| E | `d52da6e` | `TypeDB.JSON.Jason` driven directly and end to end as the configured codec. Coverage 0.00% → 100%. | The consumer application was run both with the optional dependencies and with none. |
| G | `6af43d6` | Both moduledocs say the `Jason` fallback cannot be reached, and why the branch is kept. | Documentation only. |
| F | `a09c581` | All 32 administrative functions, and the five `TypeDB` delegates, take `:timeout` and `:deadline`. | Measured against a socket that accepts and never answers: 8s connection default vs 501ms for a per-call 500ms. Neutering the forwarding fails it. |

### Corrections to the plan, made while executing

Both were reported at the time rather than absorbed:

- **Step 2 was a patch in the plan and is a minor.** `owned?` is a new field on
  the public `%TypeDB.HTTP.Httpc{}` struct, so `test/api_snapshot.txt` moves.
  The field was kept rather than worked around: `TypeDB.HTTP.Finch` has published
  `owned?: boolean()` in the same file since 0.1.x, and the two agreeing is
  finding H itself.
- **Step 5's dependency could not be `only: [:dev, :test]`.** `:req` requires
  `:jason` at `:prod`, so Mix rejects the environment restriction. It is declared
  `optional: true` instead, exactly as `:decimal` already is — used only if the
  host application has it, resolvable so the expected version is visible, never
  fetched on its own.

### Version impact

**The next release is a minor**, 0.6.0 under this project's 0.x rule, on account
of steps 2 and 7. Nothing was removed and nothing changed shape: step 7's
functions keep their old arities, generated by the default argument, so existing
calls compile and behave as before. Step 4 changes which exception an invalid
argument raises — `ArgumentError` instead of `FunctionClauseError` — which is not
a covered surface, and is called out because it is a behaviour change.

### Raised as judgement calls, then decided

Two things were left for the maintainer at the end of the refactor and settled
immediately afterwards, in `0.6.0`. Both are recorded here because the reasoning
matters more than the outcome.

1. **`create_if_not_exists/3` spent the caller's budget twice — fixed.** It makes
   two requests and gave each the full `:timeout` and `:deadline`, so
   `deadline: 5_000` could cost ten seconds. `:deadline` is documented as the
   budget for *the whole call*, and the caller made one call, so the second
   request now gets what the first did not spend. Measured: 1203ms before, under
   1100 after; the test fails without the arithmetic. `:timeout` is deliberately
   unchanged — it bounds one attempt, and these are two.
2. **`:deadline` cannot interrupt a blocking connect — documented, not fixed.**
   Against a host that accepts nothing, a call with `deadline: 300` still takes
   the full `connect_timeout`: the budget is enforced between attempts and by
   shortening each attempt's *receive* timeout, while opening the socket is
   bounded by `:connect_timeout` alone. Fixing it is possible for
   `TypeDB.HTTP.Req` and `TypeDB.HTTP.Httpc`, whose connect timeout is per
   request, and impossible for the default: Mint reads it from a pool built once.
   Doing it for two adapters out of three would make one option mean different
   things depending on the transport — which is Audit I's finding M2, and the
   reason this driver does not do that. Now stated in `TypeDB.Config` and in
   `guides/errors-and-retries.md`, with the advice to size the two together.

**Nothing from Audit II is open.**

### Found by CI after the refactor

One flaky test, mine, from step 7. The check that every accepted option value is
accepted feeds each call `timeout: 1` — one millisecond, in the list precisely to
prove that 1 is legal — and rescued only `ArgumentError`. One millisecond is also
long enough to expire, and `exists?/3` is documented to raise anything that is
not a clean 404, so on a slow enough adapter a `%TypeDB.Error{}` escaped. Twelve
local matrix runs missed it; CI failed on two of five entries at the first
attempt. Fixed in `890b194`: the rescue ignores a `TypeDB.Error`, since the test
is about the option being accepted rather than the request succeeding, and still
fails on an `ArgumentError` — checked by making a validator reject the value.

Worth recording as a method note rather than a defect: a local run is not proof,
and a green matrix repeated a dozen times is still not proof of the absence of a
race.

---

# Audit I — 0.1.0

Audited at `b96ae98` (main). Method: seven parallel auditors, one per category, each finding then
handed to an independent reviewer whose job was to refute it; 46 raw findings, 18 refuted, 28
confirmed. Every finding below was additionally **reproduced by running code** or by reading the cited
line — the reproduction script is named where one exists.

Duplicates reported by more than one auditor have been merged.

> **All findings below are fixed.** The refactor ran as `REFACTOR_PLAN.md` sequenced it, in fifteen
> commits from `0e5b005` to `babcbe3`. See [Status after the refactor](#status-after-the-refactor) at
> the end for what changed where, what was found along the way, and the one call left open.
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

### Settled

1. **The `:closed` error kind is gone** — you approved dropping it. Keeping it would have meant
   client-side transaction state, which the driver holds none of by design; producing it would make
   `close/1` and `commit/1` mutate a struct the caller holds by value.
2. **`mix typedb.check` needs a POSIX shell** — accepted: Linux is the primary target, and Git Bash
   (or WSL, or MSYS2) covers Windows. Recorded in the task's moduledoc and in README.md, and a missing
   `sh` is now a `Mix.raise` naming those three, rather than an `:enoent` from `System.cmd/3`. This is
   the only part of the project that shells out; the driver itself is pure Elixir.

### Still open for you

One judgement call, not blocking:

- **`Duration.to_iso8601/1` raises on a negative component** rather than emitting `"P-1Y-2M"`, which
  its own `parse/1` rejects. Raising from a rendering function is a strong choice; the alternatives
  are returning `{:error, reason}` and changing the signature, or normalising silently. Only reachable
  from a hand-built struct — TypeDB never sends a negative duration — so nothing in practice depends
  on it either way.
