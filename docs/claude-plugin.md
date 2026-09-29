# The Claude plugin

`plugin/` is a [Claude plugin](https://claude.com/docs/plugins/build): three
skills that teach Claude to write TypeQL 3 and to use these two packages. It is
documentation, not code — no MCP server, no hooks, no commands, no agents, no
scripts, no `bin/`. Installers get only the `plugin/` folder, so everything the
skills need is inside it.

*Written 2026-09-30 against the plugin directory's
[pre-submission checklist](https://claude.com/docs/plugins/pre-submission-checklist)
and `claude` CLI 2.1.285.*

## What is in it

| path | what it is |
| --- | --- |
| `plugin/.claude-plugin/plugin.json` | the manifest: `name`, `displayName`, `version`, `description`, `author`, `license`, `repository` |
| `plugin/README.md` | the directory shows this as the listing's description; it must be at least 40 words outside code blocks |
| `plugin/LICENSE` | Apache-2.0, a copy of the repository's |
| `plugin/skills/typeql-3/SKILL.md` | TypeQL 3: schema, data, `fetch`, `reduce`, functions, and the 2.x forms 3.x rejects |
| `plugin/skills/typedb-elixir-driver/SKILL.md` | the `typedb` package: connection, transaction types, `given_rows`, answers, errors, streaming, HTTP vs gRPC |
| `plugin/skills/typedb-elixir-testing/SKILL.md` | testing an application: a database per test, the seam to fake, provoking transport failures |
| `plugin/evals/` | five `claude plugin eval` cases, four positive and one negative |

## The two rules the content follows

**Every driver function named in a skill is in the documented public API.** The
`@doc false` functions are callable and are not promises — 0.11.0 narrowed ten of
them out of the surface for exactly that reason. `test/api_snapshot.txt` is the
source of truth, and the check is mechanical: extract every `TypeDB.*.function`
token from the skills, generate the public set from the compiled application the
way `api_snapshot_test.exs` filters it, and compare.

**Every claim about TypeDB's behaviour was run against a live server.** The same
rule the rest of this repository follows. The TypeQL skill's error codes —
`SYR1`, `TQL0`, `DEX31`, `REX3`, `SVL50`, `SVL51`, `LIT255`, `CNT9`, `FER20` —
are what TypeDB CE 3.12.1 answered, not what seemed likely. Two claims were
wrong when measured and were corrected before shipping: `put` with a changed
attribute fails `CNT9` under a `@key` rather than silently inserting a duplicate,
and `@subkey` is unimplemented in 3.12.1.

## Versioning

`plugin.json`'s `version` tracks the `typedb` package's version, and the
directory re-scans on each commit to the branch it follows. So a release of
`typedb` raises it, in the same commit that raises `typedb/mix.exs` —
`docs/releasing.md` names the step. A plugin whose `version` never moves looks
abandoned in the listing.

`name` is permanent. It cannot change after the plugin is listed, which is why it
is `typedbex`, the repository's own name, rather than anything built on
`typedb`.

## Checking it

```shell
claude plugin validate ./plugin
```

That is a syntax and schema check on the manifest and each skill's front matter,
and CI runs it on every push — the `Claude plugin validates` job in
`.github/workflows/ci.yml`. It needs no credentials and makes no model call:
measured with an empty `HOME` and no `ANTHROPIC_*` variable set.

It does **not** check the directory's own requirements — the README's length, the
licence, or whether the name is taken. Only the **Validate** button in the
[developer portal](https://claude.ai/directory/manage) does that, against a
commit it reads from the repository. CI additionally counts the README's words,
because that one is cheap.

## Measuring whether it helps

```shell
cd plugin
claude plugin eval .
```

Each case runs three times with the plugin and three times without it, and the
`Δ` column is what the plugin contributed. A case scoring 1.00 in both arms is a
case the plugin did not affect — worth deleting from the suite, or worth a
skill that actually changes the answer. Every run is a real model call on the
account that starts it, so this is a human's command rather than a CI job.

The five cases are a schema (does Claude write 3.x declarations or 2.x `sub`
forms), a user-supplied value (`given_rows` or string interpolation), a write
conflict (does it re-run the block or believe `:max_retries` covers a rejected
commit), test isolation (a database per test), and one unrelated Elixir question
that no skill should answer.

## Submitting it

A worker never submits — the person does, from
[claude.ai/directory/manage](https://claude.ai/directory/manage). What to enter:

| field | value |
| --- | --- |
| what to submit | **Plugin bundle** |
| repository | `NoeticEcho/TypedbEx` |
| plugin path | `plugin` |
| tracked branch | `main` |

Then **Validate**, fix anything marked **Blocking**, and submit. A finding marked
**Policy hold** is not a rejection: a reviewer reads that version first.

One hold is likely and is worth expecting rather than being surprised by. The
checklist holds a `displayName` or `author.name` that could be mistaken for a
brand that is not yours, and `displayName` is *TypedbEx — TypeDB for Elixir*.
The plugin's answer to a reviewer is in three places already: the `description`
says "community", the README says plainly that the project is not affiliated
with or endorsed by TypeDB Ltd. and that TypeDB Ltd. publishes no Elixir driver,
and the README's licence note attributes the trademarks. Keeping "TypeDB" in the
label is deliberate — a plugin for a TypeDB driver that does not say TypeDB is
not findable — and nominative use with an explicit disclaimer is what the hold
exists to check.

## Reference

- Build a plugin: <https://claude.com/docs/plugins/build>
- Pre-submission checklist: <https://claude.com/docs/plugins/pre-submission-checklist>
- Submit: <https://claude.com/docs/plugins/submit>
- Plugin evals: <https://code.claude.com/docs/en/plugin-evals>
