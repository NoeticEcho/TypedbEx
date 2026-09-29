# Releasing

Two packages live in this repository and each releases on its own. This is the
coordinator's runbook: what to do, in order, and what each step is protecting
against. `typedb/CONTRIBUTING.md`'s *Releasing* section is the contributor-facing
version of the same procedure for `typedb` alone; this one covers both packages
and the parts only the coordinator does.

*Written 2026-09-29, from the releases of `typedb` 0.10.1 through 0.10.4 and
`typedb_grpc` 0.3.1. Every number and URL below was checked against the
repository, the workflow files or the hex.pm API rather than remembered.*

| | `typedb` | `typedb_grpc` |
| --- | --- | --- |
| directory | `typedb/` | `typedb_grpc/` |
| tag | `vX.Y.Z` | `typedb_grpc-vX.Y.Z` |
| workflow | `.github/workflows/release.yml` | `.github/workflows/release-grpc.yml` |
| trigger | `push` on tags `v*` | `push` on tags `typedb_grpc-v*` |
| gate in the workflow | unit suite ×3 adapters | full suite **including integration**, against a `typedb/typedb:3.12.1` service |
| typical run | 3.5–4.5 min | 4.5–6 min |

The two tag globs do not overlap — `typedb_grpc-v0.3.1` does not match `v*` —
and that separation is the reason for the prefix. A shared `v*` would fire both
workflows on one tag and one of them would publish a version it does not have.

**Pushing the tag is the point of no return.** Everything else happens before it.

## Only the coordinator releases

A worker never pushes `main` or a tag. A worker's epic ends at a merged pull
request; the version bump, the tag and the watch are the coordinator's.

## 1. Decide the number

The project is in `0.x`, where a **minor** carries anything `1.x` would call
breaking and a **patch** carries anything it would not. `typedb/CONTRIBUTING.md`
has the full list under *What the version number covers*; the fastest single
question is the API snapshot:

```shell
git diff v0.10.4..HEAD -- typedb/test/api_snapshot.txt
```

A non-empty diff means the public surface moved. An empty one does **not** mean
nothing happened: a changed default, a renamed telemetry event or a new
`TypeDB.Error` `:kind` is breaking and the snapshot cannot see any of them.

Since 2026-09-29 the snapshot marks internal entries with a trailing
`# @doc false`. Lines carrying that marker are not part of the promise; a diff
that touches only those lines is a patch.

`typedb_grpc` pins its sibling with `@typedb_requirement "~> 0.10.0"`, so a
**minor** of `typedb` forces a matching release of `typedb_grpc` — under the
`0.x` rule the next minor may break it, and `~> 0.10.0` deliberately does not
reach it. A patch of `typedb` does not.

## 2. Prepare the commit

Do all of this on a branch, and merge it to `main` through a pull request with
CI green. The tag is then cut on a `main` commit that CI has already passed.

1. Close what landed in `bd`, and check nothing in flight was meant to be in
   this release.
2. Bump `@version` in the package's `mix.exs`.
3. Add the `## [X.Y.Z] - YYYY-MM-DD` section to that package's `CHANGELOG.md`
   **and its link at the bottom of the file**. Both workflows `grep` for the
   heading — but only after the tag is pushed. `typedb`'s
   `test/typedb/release_test.exs` asks the same question of the working tree,
   so bumping the version and running `mix test` tells you what is left.
4. Update the version in that package's `README.md` installation snippet, and
   in `typedb/notebooks/getting_started.livemd`'s `Mix.install/2` if the new
   version no longer satisfies what it pins. Both are asserted by the suite.
5. Write the release's own paragraph. Say what changed for someone who already
   uses the driver; anything working code can notice goes under *Upgrading*.

## 3. Run the gate locally

The release workflows deliberately run less than CI: `release.yml` skips the
integration and TypeQL jobs so that an outage at `repo.typedb.com` cannot block
a release. That makes the local gate the one that covers them.

```shell
cd typedb        # or typedb_grpc
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer
for adapter in finch req httpc; do TYPEDB_TEST_ADAPTER=$adapter mix test; done   # typedb only
mix test --cover
docker compose up -d                              # from the repository root
TYPEDB_INTEGRATION_URL=http://localhost:8000 TYPEDB_SLOW_TESTS=1 \
  mix test --include integration
mix typedb.check                                  # typedb only
mix hex.build
mix docs
```

`mix hex.build` is the step that catches a new directory nobody added to
`:files`, and for `typedb_grpc` it also refuses a path dependency on the
sibling — which is what `TYPEDB_GRPC_PUBLISH=1` switches to a version
requirement. Read `doc/index.html` after `mix docs`: the guides should render
and the sidebar groups should be right.

## 4. Order, when both packages move

`typedb` first, and it must be **live on hex.pm** before the `typedb_grpc` tag
is pushed. `release-grpc.yml` runs `mix deps.get` with `TYPEDB_GRPC_PUBLISH=1`,
which resolves `typedb` from hex rather than from the path; a tag pushed too
early fails on the first step and has to be re-cut.

On 2026-08-30 the two releases were cut seven minutes apart in exactly that
order — `v0.10.0` at 15:48 UTC, `typedb_grpc-v0.2.0` at 15:55.

## 5. Tag

```shell
git push origin main
git tag -a v0.10.5 -m "v0.10.5 — one line on what this release is"
git push origin v0.10.5
```

The tag message becomes the GitHub Release body (`gh release create
--notes-from-tag`), so it is worth a sentence rather than a version number.

Each workflow then re-checks the tag against `mix.exs` and the CHANGELOG, runs
its gate, publishes with the `HEX_API_KEY` secret from the `hex` environment,
and creates the GitHub Release.

## 6. Verify

```shell
curl -s https://hex.pm/api/packages/typedb      | jq -r .latest_stable_version
curl -s https://hex.pm/api/packages/typedb_grpc | jq -r .latest_stable_version
curl -s -o /dev/null -w '%{http_code}\n' -L https://hexdocs.pm/typedb/0.10.5/readme.html
```

hexdocs builds separately from the package and can fail on its own, so the
version being on hex.pm is not evidence that its documentation is. Then install
the package somewhere that is not this repository: the optional-dependency job
exists because a package can compile here and not there.

## When it goes wrong

**The run fails before `Publish to hex.pm`.** Nothing was published and the
number is not spent. Fix the cause, delete the tag locally and remotely, tag
again.

```shell
git tag -d v0.10.5
git push origin :refs/tags/v0.10.5
```

This path has been walked: run 16 of `Release` (2026-08-13) was a `v0.11.0` tag
pushed on the 0.9.0 commit. *Verify the tag matches the version in mix.exs*
stopped it 37 seconds in, no `v0.11.0` release exists, and 0.11.0 was never
published. That guard is why the tag is recoverable at all.

**The run fails after `Publish to hex.pm`.** The version exists on hex.pm and
the number is spent. `mix hex.publish --revert X.Y.Z` works for one hour after
publishing an existing package's new version, and not after. (A brand-new
package — a first release, as `typedb_grpc` 0.1.0 was — has 24 hours.)

```shell
cd typedb && mix hex.publish --revert 0.10.5
```

Past the hour, do not try to unpublish — release a patch. Retiring a version
leaves it installable but flags it for anyone who resolves it, which is the
right tool for "this release is broken, use the next one":

```shell
mix hex.retire typedb 0.10.5 invalid --message "Broken decode path; use 0.10.6"
```

`invalid`, `security`, `deprecated`, `renamed` and `other` are the reasons Hex
accepts, and `--message` is required (140 characters). Retiring is reversible —
`mix hex.retire typedb 0.10.5 --unretire` — where publishing is not: a version
number, once published, is never reused.

**A tag was pushed and no workflow ran.** Check the prefix. `v*` fires
`release.yml` and `typedb_grpc-v*` fires `release-grpc.yml`; anything else
fires neither, silently.

## What a release does not do

It does not touch `noetic_knowledge`. That repository depends on `typedb`
(`~> 0.10.0`), so a **minor** release here is a dependency bump there — a
separate piece of work, tracked separately.
