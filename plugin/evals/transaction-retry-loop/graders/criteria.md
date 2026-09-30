---
type: llm
---
The reply is Elixir handling a write conflict between concurrent TypeDB
transactions.

PASS if it re-runs the whole unit of work — a `TypeDB.transaction/5` call, or an
explicitly opened transaction, wrapped in a loop or recursive function that calls
it again — and decides whether to retry from the error value, for example with
`TypeDB.Error.retryable?/1` or by matching the error code `STC2`.

FAIL if it relies on the driver's own `:max_retries` option to recover from the
rejected commit, or says the driver retries a failed commit, or retries only the
individual query rather than the whole transaction.

Ignore the number of attempts, whether it backs off, and the business logic
inside the transaction.
