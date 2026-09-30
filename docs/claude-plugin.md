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
| `plugin/.claude-plugin/plugin.json` | the manifest — identity, licence, and the [listing fields](#the-listing-fields) the directory reads |
| `plugin/.claude-plugin/icon.svg` | the listing's icon: 128x128, our own mark, nobody else's logo |
| `plugin/README.md` | the directory shows this as the listing's description; it must be at least 40 words outside code blocks |
| `plugin/LICENSE` | Apache-2.0, a copy of the repository's |
| `plugin/skills/typeql-3/SKILL.md` | TypeQL 3: schema, data, `fetch`, `reduce`, functions, and the 2.x forms 3.x rejects |
| `plugin/skills/typedb-elixir-driver/SKILL.md` | the `typedb` package: connection, transaction types, `given_rows`, answers, errors, streaming, HTTP vs gRPC |
| `plugin/skills/typedb-elixir-testing/SKILL.md` | testing an application: a database per test, the seam to fake, provoking transport failures |
| `plugin/evals/` | four `claude plugin eval` cases: three that measure a contribution, one negative guard |
| `docs/plugin-privacy.md` | the privacy policy the listing links to: the plugin collects, stores and sends nothing |
| `docs/plugin-terms.md` | the terms the listing links to: Apache-2.0, no warranty, no service |

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

## The listing fields

The directory's **Listing details** step reads `plugin.json`, so the fields that
shape the listing live there rather than in the portal:

| field | value |
| --- | --- |
| `icon` | `./.claude-plugin/icon.svg` |
| `documentationUrl` | this page, on GitHub |
| `supportUrl` | the repository's issues |
| `privacyPolicyUrl` | `docs/plugin-privacy.md` |
| `termsOfServiceUrl` | `docs/plugin-terms.md` |
| `classification` | `{ "primaryCategory": "developer-tools" }` |

**None of these six is documented.** They appear in neither the [manifest
reference](https://code.claude.com/docs/en/plugins/manifest-reference) nor any of
the eleven plugin and directory pages searched for them. They are real all the
same, and that was established rather than assumed: `claude plugin validate`
warns on an unknown top-level key and fails `--strict` for it, so a control key
was put through the same run — it warned and failed, while all six of these
passed silently. The four URL keys also turn up in the CLI's own key-normalisation
table, each with snake_case aliases (`privacy_policy`, `terms_of_service`,
`support`, `bugs`, `docs`), beside a seventh field, `screenshots`, that this
plugin has no use for.

What the validator does **not** do is check their values. It accepts a
`classification` that is a bare string, and an `icon` pointing at a file that is
not there — both measured. So `classification`'s shape is the one thing here that
only the portal's **Validate** can confirm. If it objects, the fix is one line in
the manifest and nothing else changes.

The icon is a graph of four nodes: deliberately not TypeDB's logo, and not
Elixir's droplet either. Neither mark is ours to ship.

## The root `.gitattributes`, and why it stays

The pre-submission checklist says to keep out of every `.gitattributes` at the
repository root, above the plugin folder and inside it, "`filter`, Git LFS
included, and other attributes that rewrite file contents". The root file here
holds:

```
*.txt text eol=lf
*.livemd text eol=lf
* text=auto
```

Whether the portal counts `text` and `eol` as rewriting content is not something
the documentation settles — it names `filter` and LFS. If it does, validation
stops with `Couldn't validate that repository`, which does not say which cause
applies.

**It stays as it is for now.** The file earns its place: `api_snapshot.txt` and
the notebook are compared byte for byte, and without the pin a Windows checkout
rewrites them to CRLF and the Windows job fails. Changing it to dodge a rule that
may not apply would trade a real guarantee for a guess.

If the portal does refuse, the minimal change is to narrow the last line so it
does not cover the plugin — nothing in `plugin/` needs its line endings pinned:

```
plugin/** -text
```

## Versioning

`plugin.json`'s `version` tracks the `typedb` package's version, and the
directory re-scans on each commit to the branch it follows. So a release of
`typedb` raises it, in the same commit that raises `typedb/mix.exs` —
`docs/releasing.md` names the step. A plugin whose `version` never moves looks
abandoned in the listing.

`name` is permanent. It cannot change after the plugin is listed, which is why it
is `typedbex`, the repository's own name, rather than anything built on
`typedb`.

Adding the listing fields did **not** move `version`: it stays at `0.11.0`, the
driver's version. Nothing in the manifest forces a bump — `version` exists to pin
installs, and the three skills are byte-for-byte unchanged, so there is no new
behaviour for an installed copy to pick up. It rises with the driver's next
release, as above.

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

Each case runs three times with the plugin and three times without it. The `Δ`
column is what the plugin contributed; a case scoring 1.00 in both arms is a case
the plugin did not affect. Every run is a real model call on the account that
starts it, so this is a human's command rather than a CI job — CI runs only
`claude plugin validate`.

### What the suite measures

The last run, on the plugin as it stands — `mean Δ +0.44`, 5 cases, 318s, $1.39:

| case | what it probes | with | without | Δ |
| --- | --- | ---: | ---: | ---: |
| `fault-injection-adapter` | making the driver fail on purpose in a test | 1.00 | 0.00 | **+1.00** |
| `user-input-as-given-rows` | a value from a web form: `given_rows` or interpolation | 1.00 | 0.11 | **+0.89** |
| `transaction-retry-loop` | a rejected commit: re-run the block, or trust `:max_retries` | 1.00 | 0.67 | **+0.33** |
| `idempotent-insert` | `put` with a changed attribute | 1.00 | 1.00 | 0.00, kept as a guard |
| `unrelated-elixir-request` | an Elixir question no skill should answer | 1.00 | 1.00 | 0.00, by design |

Across four rounds the two driver cases were stable — `given_rows` scored a
baseline of 0.33, 0.33, 0.33 and 0.11, and the retry case 0.50, 0.50, 0.67 and
0.67 — so the contribution is real rather than a lucky sample. `idempotent-insert`
scores 1.00 in both arms on purpose: it guards against the skill making a correct
answer worse.

`fault-injection-adapter` is the clearest result: **without the plugin the
baseline scores 0.00**, because nothing in a model's training says
`TypeDB.HTTP` is a behaviour you can implement and pass as `:http`. It reaches
for Mox instead, which tests that you called a function rather than that the
driver survives a dropped request.

`user-input-as-given-rows` is the one that matters most, because the failure is a
security failure: in all three baseline runs Claude produced a query without
`given_rows`.

### What it does not help with, measured

**Writing TypeQL 3 from scratch.** Five probes across four eval rounds — writing
a schema (twice), diagnosing a `SYR1` error, paging a `fetch`, and `put`
semantics — every one scored **1.00 with the plugin and 1.00 without it**. A
frontier model already writes correct TypeQL 3; the language is public and
documented, and the plugin adds nothing to it.

That is why `skills/typeql-3/SKILL.md` was cut down rather than kept as a
reference. What remains is only what a measurement showed is *ours* to
contribute: the `SYR1` trap, the 2.x table, `@subkey` being unimplemented,
reserved keywords, the `put`/`redefine`/`undefine` behaviours with data present,
and the error-code table — each of them a fact about what 3.12.1 actually
answers. The schema tutorial, the literals it can already guess and the general
query reference went.

The `diagnose-2x-schema-error` case was cut for a second reason worth recording:
the skill **never loaded** in any of its three runs (`Skill called 0x`) and Claude
answered correctly anyway. The trigger gap was real and was fixed — `typeql-3`'s
`description` now names the error codes, so a pasted `SYR1` loads it — but the
case measured nothing and was removed.

### A grader that lied

The first round scored `schema-in-3x-form` at 0.89 **with** the plugin, and the
failing grader was a regex asserting the answer contained no `sub entity`. The
answer was correct; its closing sentence was *"It follows the 3.x syntax: `entity
book`, not `book sub entity`"* — the skill's own contrast, quoted back. A regex
over prose cannot tell a warning from a mistake. The rubric now says so
explicitly, and the lesson generalises: grade the artefact, and let a judge with a
written-out rubric handle anything that needs reading.

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

The **Listing details** step needs nothing typed into it: the icon, the four
links and the classification all come from `plugin.json` — see [the listing
fields](#the-listing-fields). The **Data handling** step does need answering, and
the answers are short, because the plugin runs no code: it reads and stores no
personal data, sends data to no service, keeps nothing, and is not aimed at
people under 18. [The privacy policy](plugin-privacy.md) says the same at
length.

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
