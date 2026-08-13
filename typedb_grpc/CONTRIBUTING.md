# Contributing to typedb_grpc

The sibling's [CONTRIBUTING.md](../typedb/CONTRIBUTING.md) covers the things
both packages share — style, versioning policy, what a commit message is for.
This file covers what is different here.

## The gate

Run from `typedb_grpc/`:

```sh
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer
mix test
```

`mix test` alone runs about a fifth of the suite. **Almost everything here is
an integration test**, and that is a decision rather than a gap: there is no
in-process stub for this transport. The sibling has one because HTTP can be
spoken by a small Plug router — and even there the project's rule is that the
stub has repeatedly been wrong about the server. A stub for a bidirectional
stream would have to reimplement request multiplexing and flow control, which is
exactly the machinery most likely to be wrong, and it would be testing my model
of TypeDB rather than TypeDB.

So the real gate needs a server:

```sh
TYPEDB_GRPC_ADDRESS=127.0.0.1:1729 mix test --include integration
```

And the shared behaviour suite needs both endpoints, because its whole value is
comparing the two drivers. It warns loudly when it runs against half the matrix:

```sh
TYPEDB_INTEGRATION_URL=http://127.0.0.1:8000 \
TYPEDB_GRPC_ADDRESS=127.0.0.1:1729 \
mix test --include integration test/behaviour
```

## The generated protocol modules

`lib/protocol/` is generated from
[typedb-protocol](https://github.com/typedb/typedb-protocol) and committed, so
that installing the package needs no `protoc`. Never edit it by hand — CI
regenerates it and diffs, so a hand edit fails the build.

```sh
mix escript.install hex protobuf   # once; put ~/.mix/escripts on PATH
mix typedb.grpc.gen 3.12.0
```

Then update `TypeDB.GRPC.Protocol.version/0` to match, and run the integration
suite against a server of that version — `TypeDB.GRPC.Server.check_protocol/2`
compares the two and the suite asserts on it.

## The dependency on `typedb`

It is a **path** dependency in this repository and a **version requirement**
when published, switched by `TYPEDB_GRPC_PUBLISH` — see `typedb_dependency/0`
in `mix.exs`. The path is the point of the monorepo: a change to the shared
structs is visible here without a release. To see the package as it will be
published:

```sh
TYPEDB_GRPC_PUBLISH=1 mix hex.build
```

Bumping the sibling's floor is a deliberate act. `@typedb_requirement` in
`mix.exs` is the one place to change it, and it should be raised when this
package starts relying on something the older version does not have — not
routinely.

## Releasing

Tags are prefixed, because two packages in one repository cannot both answer to
`v*`:

| package | tag | workflow |
| --- | --- | --- |
| `typedb` | `v0.8.0` | `.github/workflows/release.yml` |
| `typedb_grpc` | `typedb_grpc-v0.1.0` | `.github/workflows/release-grpc.yml` |

To cut a release: bump `@version` in `mix.exs`, move `## [Unreleased]` in
`CHANGELOG.md` to `## [X.Y.Z] - YYYY-MM-DD`, commit, then

```sh
git tag -a typedb_grpc-v0.1.0 -m "0.1.0"
git push origin typedb_grpc-v0.1.0
```

The workflow re-runs the gate against the publishable shape of the package,
publishes, and creates the GitHub Release.

## Creating the package on hex.pm the first time

**The first publish is manual, and deliberately so.** It claims a global name
on a shared registry, ties the package to an owner account, and cannot be
undone — `mix hex.publish --revert` works for an hour and the name is never
released. That is not a thing to discover a CI workflow has done.

Everything below runs from `typedb_grpc/` on a maintainer's machine.

**1. Check the name is free.** It was when this was written, but names are
claimed continuously:

```sh
mix hex.info typedb_grpc
#=> No package with name typedb_grpc
```

A taken name prints the package's description and its `Config:` line instead.

Not `mix hex.package fetch typedb_grpc 0.0.1` — that answers about a *version*,
so it returns the same `Request failed (404)` for a free name and for a taken
one that simply has no `0.0.1`. Checked against `typedb`, which is very much
taken and answers 404 to exactly that command.

If the name is gone, it is in `package/0` in `mix.exs` and does not have to
match the application name.

**2. Have a hex.pm account, and authenticate.**

Registration is on the site — <https://hex.pm/signup>. Hex 2.5 has no
`mix hex.user register`; it had one once, and instructions that still say so are
older than the tool. Then, on the machine that will publish:

```sh
mix hex.user auth
```

That authorizes the local machine and stores a key for it.

**3. Check what will be published.** `files:` in `package/0` decides, and
`lib/protocol` is 3,000 generated lines that must be in it — the package is
unusable without them and nothing at install time can regenerate them:

```sh
TYPEDB_GRPC_PUBLISH=1 mix hex.build
tar -xOf typedb_grpc-*.tar contents.tar.gz | tar -tz | sort
```

Confirm that `lib/protocol/` is present, that the dependency on `typedb` shows
a version rather than a path, and that nothing private crept in.

**4. Publish.**

```sh
TYPEDB_GRPC_PUBLISH=1 mix hex.publish
```

It prints the package, its dependencies and its files, and asks for
confirmation. It publishes the docs alongside, from the `:docs` environment.

**5. Check what landed.** Hexdocs builds separately from the package and can
fail on its own:

- <https://hex.pm/packages/typedb_grpc>
- <https://hexdocs.pm/typedb_grpc>

**6. Give CI the key it needs**, if it does not have one. The release workflow
authenticates with a `HEX_API_KEY` secret, in the repository's `hex`
environment.

Generate it in the dashboard — <https://hex.pm/dashboard/keys> — with the
`api:write` permission. There is no `mix` task for this on a personal account
in Hex 2.5: `mix hex.organization key ... generate` exists but issues keys for
an *organization*, and `mix hex.user auth` stores a key locally rather than
printing one to paste elsewhere.

It is the same secret the sibling's release workflow uses, so if `typedb`
already releases from CI there is nothing to do here.

**7. Add owners**, so the package does not depend on one person's account:

```sh
mix hex.owner add typedb_grpc someone@example.com
```

After all this, every subsequent release goes through the tag and the workflow,
and none of these steps are repeated.
