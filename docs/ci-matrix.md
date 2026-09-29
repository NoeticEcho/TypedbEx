# What CI covers, and why each slot is there

`.github/workflows/ci.yml` is CI's definition; this is the short note on how to
read it. Every number here was measured, and each says where.

## The version matrix

| axis | slots | why these |
| --- | --- | --- |
| Elixir / OTP (`typedb`) | 1.20/29, 1.19/28, 1.18/27, 1.18/25 | the newest, the two between, and the oldest the package claims. 1.18/25 is not decoration — it is the row that caught `:timer.tc/2`'s meaning changing in OTP 26 |
| Elixir / OTP (`typedb_grpc`) | 1.20/29, 1.18/27 | narrower on purpose: `:grpc` and `:protobuf` set the floor there, and widening it would test their support rather than ours |
| TypeDB | 3.12.0, 3.12.1, `latest` | the oldest supported, the one the driver is developed against, and the newest, so a TypeDB release breaks this build before it breaks an application |
| HTTP adapter | Finch, Req, `:httpc` | the three are interchangeable by design and only the matrix proves it |
| OS | Ubuntu, Windows | the driver is pure Elixir; `mix typedb.check` shells out and says so |

The `latest` slot pins an image that is *not* `latest` when the tag is broken —
currently 3.12.1, because 3.13.0-rc0 panics on its own. The slot is kept rather
than deleted so that a matrix which has quietly stopped testing the newest
server stays visible; `ci.yml` says how to undo it.

## The oldest TypeDB

3.12.0, measured rather than reasoned about: on 3.11.5 the suite fails 32 tests
and invalidates ten more. `typedb/README.md`'s *Requirements* section has the
breakdown by cause. The floor is in the matrix so that the claim keeps being
re-run — its predecessor said "fourteen", which was true when written and drifted
as the suite grew.

## The coverage floor

Each package fails its build below a floor set at what it measures today, and
the step prints the delta so the headroom is visible:

```
coverage 87.86% against a floor of 85% (+2.86 points)
```

A floor only moves up. The numbers live in each package's `mix.exs` under
`test_coverage`, along with what is excluded and why — test support and macros
for `typedb`, and protoc-gen-elixir's three thousand generated lines for
`typedb_grpc`.

`typedb_grpc`'s floor is low (20%) and honestly so: its tests are mostly
integration tests that skip without a server, so a `--cover` run exercises the
error mapping, the config and the protocol assertions and little else. It
catches a deleted unit test; it does not claim the driver is 20% tested.

## The jobs that need a server flag

A service container's command cannot be overridden, so anything needing server
flags runs `docker run` in an ordinary step instead: five-second tokens (token
renewal), TLS, and the restart suite. They were run by hand until 0.4.1, which
is another way of saying they were run when someone remembered.

## The soak

`typedb/test/integration/soak_integration_test.exs` runs inside the ordinary
integration job — 200 concurrent reads, 100 concurrent writes checked for
exactly-once, and 25 concurrent explicit transactions — and costs 0.3 s through
Finch and 1.3 s through `:httpc`. It asserts no durations and sleeps nowhere;
the file's moduledoc says what makes it safe to run on every push.
