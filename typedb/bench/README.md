# Benchmarks

Plain scripts, no benchmarking library: they are run rarely, by hand, and a
dependency that exists only for them would be carried by everyone who reads
`mix.lock`.

```shell
mix run bench/decode.exs                      # no server needed
mix run bench/decimal.exs                     # no server needed
docker compose up -d
TYPEDB_BENCH_URL=http://localhost:8000 mix run bench/transport.exs
TYPEDB_BENCH_URL=http://localhost:8000 mix run bench/answer_size.exs
TYPEDB_BENCH_URL=http://localhost:8000 mix run bench/given.exs
```

Every script prints the machine and the versions it ran on before its first
number, because a number without them cannot be checked by anyone later. If you
change one, re-run it and update whatever quotes it.

## Which claim comes from which script

Every number about speed or throughput published in `README.md`, in the
`[Unreleased]` section of `CHANGELOG.md`, or in a moduledoc, comes from one of
these:

| claim | script | needs a server |
| --- | --- | --- |
| the HTTP adapter table — req/s and p50 per concurrency | `transport.exs` | yes |
| bytes on the wire and bytes decoded, per row | `answer_size.exs` | yes |
| `given_rows` against one-statement-per-row and one-big-query | `given.exs` | yes |
| per-value cast cost by value type; the cost of `Code.ensure_loaded?/1` | `decode.exs` | no |
| the decimal path, and what resolving `Decimal` at compile time is worth | `decimal.exs` | no |

Numbers about **TypeDB's own behaviour** rather than the driver's speed — the
300,000 ms transaction lifetime, the 10,000-answer cap, the 2 MiB request-body
limit — are not benchmarks and are not here. They are pinned by the integration
suite, which re-runs them on every push against three TypeDB versions; that is a
stronger guarantee than a script anyone has to remember to run.

## Absolute numbers versus ratios

**The ratio is the finding; the absolute number is a property of the machine.**
`transport.exs` on the container that produced this paragraph reports Finch at
2,252 req/s and `:httpc` at 380 req/s at 200-way — different absolute numbers
from the README's table, the same three-to-four-fold ratio. Quote a ratio when
you can, and name the machine when you quote an absolute.

This has bitten once already. 0.1.0 published 77 req/s for `:httpc` at 200-way;
it did not reproduce, and the 0.6.0 entry in `CHANGELOG.md` says so. A figure
that survives in one place after being corrected in another is worse than no
figure, because it reads as a measurement.

## Numbers in released CHANGELOG sections

Sections for versions already released are a record of what was measured at the
time, on the machine of the day, and are left as they were written — rewriting
them would make the history less true rather than more. Where such a number was
later found not to reproduce, the entry that supersedes it says so; the 0.6.0
entry is the worked example. New entries name their script.
