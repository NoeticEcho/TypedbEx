# Privacy policy — the TypedbEx Claude plugin

*Applies to the `typedbex` plugin in `plugin/`, published from
[NoeticEcho/TypedbEx](https://github.com/NoeticEcho/TypedbEx). Last updated
2026-09-30.*

**The plugin collects nothing, stores nothing, and sends nothing anywhere.**

It cannot, and that is a property of what it is rather than a promise about how
it behaves. The plugin is three Markdown skill files, a manifest, an icon, a
licence and a README. It contains:

- no MCP servers and no connectors
- no hooks, commands, agents or workflows
- no scripts, executables or `bin/` directory
- no network calls, no telemetry, no analytics, no logging
- no `userConfig`, so it never asks you for a value and never holds one

There is no code in it to run. Installing it adds documentation that Claude
reads when your request matches one of the three skills; everything else is
unchanged.

## What the skills tell Claude to do with your data

Nothing is sent to us or to any third party. The skills teach Claude how to
write TypeQL and Elixir. Any query Claude then writes runs against **your own**
TypeDB server, from your own machine or infrastructure, under your own
credentials — the same as code you write by hand. We never see it.

The skills deliberately instruct Claude to read a database password from your
environment rather than write it into code, and never to interpolate a value
into a query string. Neither practice sends anything to us.

## Links in the skills

The skills cite documentation — `hexdocs.pm`, `typedb.com`, `github.com`.
Following one is an ordinary web request that you or Claude make, subject to
those sites' own policies. The plugin does not fetch them on its own.

## Changes

This page is versioned in the repository alongside the plugin. A change to it
arrives in the same way any other change does: a commit, and a new plugin
version.

## Contact

Open an issue at
<https://github.com/NoeticEcho/TypedbEx/issues>. For anything you would rather
not post publicly, use the repository's
[Security tab](https://github.com/NoeticEcho/TypedbEx/security).
