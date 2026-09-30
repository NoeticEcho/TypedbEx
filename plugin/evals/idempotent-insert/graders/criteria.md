---
type: llm
---
The user wants an idempotent write in TypeQL 3 that also updates an attribute,
on a schema where `name` is a `@key`.

PASS if the reply makes clear that a single `put` carrying the new age does not
do this — because `put` matches on the whole pattern, so a changed `age` makes it
try to insert a second person, which the `@key` on `name` rejects — and gives a
working answer: `put` with only the identifying attribute (`name`) followed by a
`match` and `update` for the age, or a `match`/`update` with a separate `put`, or
two statements achieving that.

FAIL if it presents `put $p isa person, has name "Alice", has age 31;` as the
answer, or says `put` updates the attributes of an existing match, or suggests
`insert` alone, or recommends deleting and re-inserting the person.

Ignore formatting, variable names, and whether it mentions a transaction type.
