# Changelog

All notable changes to this package are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Telemetry, a TLS suite, and Audit V — the package's first, which found nine
things including two critical ones that every existing test was blind to:
`datetime-tz` decoded to a different type *and* a different instant than the
sibling, and two processes sharing one transaction handle lost one of them.
Both are fixed, with tests that fail when the defect is put back.

The package is feature-complete against `typedb`. Nothing released yet. The package is being built; see the repository's
`AUDIT.md` and the `Монорепо и gRPC-драйвер` epic in `bd` for what is done and
what is not.
