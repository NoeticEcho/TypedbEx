---
type: llm
---
The reply explains how to isolate ExUnit tests that talk to TypeDB.

PASS if it gives each test its own database — a name made unique per test, for
example with `System.unique_integer/1` — created in `setup` and dropped
afterwards, typically in `on_exit`.

PASS also, and it is better, if it additionally warns that a `:schema`
transaction takes a database-wide lock, or that `TypeDB.query/4` defaults to
`:schema` so tests left on the default serialise, or that two tests starting a
connection under the same name collide.

FAIL if the advice is to share one database and clean it between tests, to run
the suite with `async: false` as the primary fix, or to mock the driver instead
of isolating the data.

Ignore module names and formatting.
