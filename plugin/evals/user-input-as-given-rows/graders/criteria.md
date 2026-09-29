---
type: llm
---
The reply is Elixir that queries TypeDB with a value supplied by an end user.

PASS if the user's value is passed as data beside the query — a `given $n: ...;`
stage in the TypeQL together with a `given_rows:` option carrying the value — and
the value is never spliced into the query string with `#{...}`.

PASS also if the code additionally passes `transaction_type: :read`.

FAIL if the user's value is interpolated into the TypeQL string in any way, or if
the value is concatenated into the query with `<>` or `String.replace`.

Judge only how the user's value reaches TypeDB. Ignore naming, module structure
and error handling.
