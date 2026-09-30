# Terms of use — the TypedbEx Claude plugin

*Applies to the `typedbex` plugin in `plugin/`, published from
[NoeticEcho/TypedbEx](https://github.com/NoeticEcho/TypedbEx). Last updated
2026-09-30.*

## Licence

The plugin is licensed under the **Apache License 2.0**, the same as the rest of
the repository. The full text is in
[`plugin/LICENSE`](https://github.com/NoeticEcho/TypedbEx/blob/main/plugin/LICENSE).
You may use, copy, modify and redistribute it under those terms, which include
the patent grant and the attribution requirement in sections 3 and 4.

## No warranty

As Apache-2.0 section 7 states, the plugin is provided **"AS IS", without
warranties or conditions of any kind**, express or implied. Section 8 excludes
liability for damages arising from its use.

In plain terms: the skills are documentation, and documentation can be wrong or
go out of date. Everything in them was verified against TypeDB CE 3.12.1 at the
time of writing, and a later TypeDB may behave differently. **Review the code and
queries Claude writes before running them**, particularly anything that writes to
or deletes from a database you care about.

## No service

Installing the plugin does not create a service relationship. There is no
uptime commitment, no support commitment and no service-level agreement.
Nothing runs on our infrastructure, because the plugin runs no code at all — see
the [privacy policy](plugin-privacy.md).

The plugin is maintained by one person, in the open, in their own time. Issues
and pull requests are welcome at
<https://github.com/NoeticEcho/TypedbEx/issues>; a reply is best effort.

## Not affiliated with TypeDB Ltd.

This is a community project. It is **not affiliated with, endorsed by, or
maintained by TypeDB Ltd.**, and it is not TypeDB's official Elixir driver —
TypeDB Ltd. does not publish one. TypeDB and TypeQL are trademarks of TypeDB
Ltd., used here only to name the database and the query language the skills
target.

## Your TypeDB server is yours

The plugin helps Claude write code that talks to a TypeDB server **you** run,
under **your** credentials and **your** agreement with whoever provides it.
Those terms are between you and them; nothing here changes them.

## Changes

These terms are versioned in the repository alongside the plugin. Continuing to
use the plugin after a change means accepting the version then published.
