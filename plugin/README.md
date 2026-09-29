# TypedbEx — TypeDB for Elixir

Three skills that teach Claude to write correct **TypeQL 3** and to use the
**`typedb`** and **`typedb_grpc`** Elixir packages the way they are meant to be
used.

This is a community project by NoeticEcho, built around the open-source driver
at [NoeticEcho/TypedbEx](https://github.com/NoeticEcho/TypedbEx). It is **not
affiliated with, endorsed by, or maintained by TypeDB Ltd.**, and it is not
TypeDB's official Elixir driver — TypeDB Ltd. does not publish one.

## What the skills know

**`typeql-3`** — schemas, data queries, `fetch` documents, aggregation and
functions in TypeQL 3, plus the 2.x forms that 3.x rejects. Every claim in it was
run against TypeDB CE 3.12.1 and reports the error code that server actually
answered. That matters most for one trap: the 2.x `define dog sub entity;` fails
with "The type 'dog' was not found", which names the wrong problem and sends
people looking for a missing type instead of a rewritten declaration.

**`typedb-elixir-driver`** — starting a connection under a supervisor, why
`transaction_type` is the option that matters most, passing user input through
`given_rows` instead of string interpolation, reading the three answer shapes,
branching on `%TypeDB.Error{}`, retrying the two failures the driver cannot retry
for you, streaming past the answer cap, and when the gRPC transport earns its
seven extra dependencies. Every function it names is in the documented public API
of `typedb` 0.11.0; that list was generated from the package itself rather than
written by hand.

**`typedb-elixir-testing`** — an ExUnit case template giving each test its own
database, why sharing one makes tests ordered, faking at your own boundary rather
than mocking the driver, and provoking timeouts and transport failures through a
custom `TypeDB.HTTP` adapter.

## Use it

Install the plugin and then just work. Ask for a schema, a query, a migration, a
retry loop or a test and the matching skill loads on its own; there are no
commands to remember. The skills also fire when a query fails — paste the error
and Claude will recognise codes like `TQL0`, `SYR1`, `CNT9`, `STC2` and `TSV12`
and say what each one means here.

The skills assume TypeDB **3.12 or newer**, which is the floor the `typedb`
package supports, and `typedb ~> 0.11`.

## Data and behaviour

This plugin is **documentation only**. It contains three Markdown skills, a
manifest, a licence and this README, and nothing else:

- no MCP servers and no connectors
- no hooks, no commands, no agents
- no scripts, no executables, no `bin/` directory
- no network requests, no telemetry, no credentials, and no configuration to fill in

It sends no data anywhere and stores nothing. It cannot: there is no code in it
to run. The only outbound requests are the ones you or Claude make by following
a documentation link.

## Licence

Apache-2.0. See [LICENSE](LICENSE).

TypeDB and TypeQL are trademarks of TypeDB Ltd., used here only to name the
database and the query language these skills target.
