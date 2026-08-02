# Benchmarks

Plain scripts, no benchmarking library: they are run rarely, by hand, and a
dependency that exists only for them would be carried by everyone who reads
`mix.lock`.

```shell
mix run bench/decode.exs                      # no server needed
docker compose up -d
TYPEDB_BENCH_URL=http://localhost:8000 mix run bench/transport.exs
TYPEDB_BENCH_URL=http://localhost:8000 mix run bench/answer_size.exs
```

Numbers quoted in `CHANGELOG.md` come from these. If you change one, re-run it
and update both.
