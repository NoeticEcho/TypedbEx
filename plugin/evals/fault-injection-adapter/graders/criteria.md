---
type: llm
---
The user wants to make the `typedb` driver fail on purpose in a test.

PASS if the reply implements the `TypeDB.HTTP` behaviour as a wrapper adapter
that returns an error for the first calls and then delegates to a real adapter,
and passes it to the connection through the `:http` option.

PASS also, and it is better, if it notes that `:max_retries` must be at least as
large as the number of injected failures — two injected failures need
`max_retries: 2`, because the default of 1 would exercise the give-up path
instead.

FAIL if it suggests mocking `TypeDB.query/4` or the whole `TypeDB` module with
Mox or a similar library instead of swapping the transport, or if it suggests
taking the real server down, or breaking DNS, or a proxy.

Ignore whether every callback of the behaviour is written out, and ignore naming.
