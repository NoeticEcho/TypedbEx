# Cloud workers

How a cloud worker's box is set up, and what a worker does with it once it is.

The container a worker wakes up in has git, curl and Docker and nothing else —
no `erl`, no `elixir`, no `mix`. `scripts/cloud-setup.sh` is what closes that
gap, and it is meant to run once, as root, in the environment's **setup
script** box rather than inside a session: a worker that installs a toolchain
on its first turn spends its first turn installing a toolchain.

## What the person pastes into the environment

**Setup script**, run as root before a session starts:

```sh
scripts/cloud-setup.sh
```

It is safe to re-run: every step is skipped when its result is already in
place. To see what it would do without it doing anything:

```sh
scripts/cloud-setup.sh --dry-run
```

The dry run prints the exact versions and SHA-256 checksums it would install,
because it reads the same index the real run does.

**Environment variables** — all optional; the defaults are what CI uses:

| variable | default | what it changes |
| --- | --- | --- |
| `OTP_SERIES` | `29` | which OTP series to take the newest build of |
| `ELIXIR_SERIES` | `1.20` | the same for Elixir |
| `OTP_VERSION` | — | an exact version instead of the newest in the series |
| `ELIXIR_VERSION` | — | the same for Elixir |
| `TYPEDB_VERSION` | `3.12.1` | must match `docker-compose.yml` |
| `PREFIX` | `/usr/local` | where Erlang and Elixir go |
| `TYPEDB_PREFIX` | `/opt/typedb` | where the TypeDB release goes, when Docker is absent |

**Hosts that must be reachable.** A filtered egress is the usual reason a
setup box fails, so every download in the script names its host when it cannot
reach it:

| host | for |
| --- | --- |
| `builds.hex.pm` | the prebuilt Erlang and Elixir, and their checksums |
| `repo.hex.pm` | `mix local.hex`, `mix local.rebar`, and every `mix deps.get` |
| `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com` | the TypeDB image, when Docker is used |
| `repo.typedb.com` | the TypeDB server release, when Docker is not |
| `github.com` | the repository itself |

Docker Hub rate-limits unauthenticated pulls, and an over-limit box gets a
`429` from `registry-1.docker.io`. The script prints that verbatim rather than
guessing: it is not a broken box, and the image may well already be there.

## Which versions, and why not `.tool-versions`

CI's lint job — `elixir: "1.20", otp: "29"` in `.github/workflows/ci.yml`, the
one that decides `mix format --check-formatted`, credo and dialyzer — is what
the script installs, because that is the verdict a worker has to predict.

`.tool-versions` says `elixir main-otp-29`. The script does not follow it, on
purpose. `main-otp-29` is a build of Elixir's development branch: the published
artefact is rebuilt as that branch moves, so "verified against its published
SHA-256" would only ever mean "whatever it is today". CI never uses it. And the
formatter is the sharp end — a `mix format` from Elixir main can produce a file
that 1.20's `--check-formatted` rejects, which is a red CI run caused by the
setup box rather than by the change.

Within a series the newest build is taken, which is what `erlef/setup-beam`
does with `otp-version: "29"`, so the box matches CI's semantics instead of
drifting from it.

## The locale

A container with no `LANG` boots the BEAM with latin1 name encoding, and then
every `mix` command opens with a paragraph saying Elixir "may malfunction". The
script writes `/etc/profile.d/beam-locale.sh` with `LANG=C.UTF-8` and
`LC_ALL=C.UTF-8`.

`/etc/profile.d` is read by login shells. A worker whose shell is not one — and
an agent's usually is not — should export them itself, or the warning comes
back:

```sh
export LANG=C.UTF-8 LC_ALL=C.UTF-8
```

## Starting TypeDB

The integration suites need a live TypeDB 3.x. One command covers both ways the
setup box can have provided it — the container from `docker-compose.yml` when
there is a Docker daemon, the unpacked release when there is not:

```sh
scripts/typedb-server start     # start it and wait until /health answers
scripts/typedb-server status    # is it serving?
scripts/typedb-server stop      # stop it
```

`start` returns only once `http://127.0.0.1:8000/health` answers, so the suite
that follows it does not race the server's boot. When it gives up it prints the
server's last lines rather than only its own verdict.

Then, from inside a package directory:

```sh
cd typedb
TYPEDB_INTEGRATION_URL=http://127.0.0.1:8000 mix test --include integration

cd ../typedb_grpc
TYPEDB_GRPC_ADDRESS=localhost:1729 \
TYPEDB_INTEGRATION_URL=http://127.0.0.1:8000 \
  mix test --include integration
```

Both default to `admin`/`password`, which is what `docker-compose.yml` starts
and what TypeDB CE ships. `TYPEDB_INTEGRATION_USERNAME`,
`TYPEDB_INTEGRATION_PASSWORD`, `TYPEDB_GRPC_USERNAME` and
`TYPEDB_GRPC_PASSWORD` override them.

Suites that need more than a stock server skip themselves unless their own
variables are set — TLS (`TYPEDB_TLS_URL`, `TYPEDB_GRPC_TLS_ADDRESS` and the
certificates beside them), restart (`TYPEDB_RESTART_URL`), short-lived tokens
(`TYPEDB_SHORT_TOKEN_URL`), the console interop check (`TYPEDB_CONSOLE`). CI
builds each of those environments in its own job; a worker needs them only when
its epic touches that ground, and `.github/workflows/ci.yml` is the recipe.

## The gate before a pull request

What CI runs, and what a worker runs before pushing, per package:

```sh
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer
mix test

# typedb only: the three HTTP adapters are interchangeable by design, and
# only the matrix proves it.
for a in finch req httpc; do TYPEDB_TEST_ADAPTER=$a mix test || break; done
```

`mix dialyzer` builds a PLT on its first run in a fresh container, which takes
a few minutes and looks like a hang. It is not one.
