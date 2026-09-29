---
type: llm
---
The user asked how to page a TypeQL 3 `fetch` query.

PASS if the reply says that a `fetch` pipeline cannot be paged — that putting
`offset` or `limit` after the `fetch` stage is rejected by the server — and gives
a way that works: page the `match` with `sort`, `offset` and `limit` and keep the
`fetch` at the end of each page, or switch to `select` and page that, or use the
driver's streaming helper.

PASS also if it puts `sort`, `offset` and `limit` before the `fetch` stage
without explicitly saying the other order fails, as long as it does not present
`fetch` followed by `offset`/`limit` as a working option.

FAIL if it shows `offset` or `limit` placed after the `fetch` stage as the
answer, or claims a `fetch` can be paged directly, or says paging is impossible
with no alternative.

Ignore formatting and whether it mentions the answer-count limit.
