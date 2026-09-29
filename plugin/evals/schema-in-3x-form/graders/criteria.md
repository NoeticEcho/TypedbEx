---
type: llm
---
The reply contains a TypeQL schema for TypeDB 3.x.

PASS if every type is declared by its kind followed by its name — `entity book,`,
`attribute title, value string;`, `relation authorship, relates ...` — and the
relation declares its roles with `relates`, and the entities take part with
`plays <relation>:<role>`, and uniqueness is expressed with `@key` or `@unique`.

FAIL if any type is declared in the TypeDB 2.x style `<name> sub entity`,
`<name> sub attribute` or `<name> sub relation`, or if roles are declared without
`relates`, or if the schema uses `rule`.

Judge only the schema. Ignore prose, formatting and whether extra explanation is
present.
