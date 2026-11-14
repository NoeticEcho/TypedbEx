# TypeDB vector search with the HNSW index: feedback on `11ab292c`

To the TypeDB team. This follows our October report on the vector-search alpha
(`docs/feedback/typedb-vector-alpha-2026-10.md`, branch
`feature/eb-5cr.6-vector-alpha`). We moved an agent-memory store onto the
indexed build and re-ran what we had found. Every finding has a snippet you
can paste.

## Environment

| | |
|---|---|
| Server | `typedb-all-linux-x86_64`, commit `11ab292cfc87a04709d1dbcd421df14152122390` (branch `vector-search-impl-indexing`, 2026-11-12), version 3.14.1-dev, in Docker on `ubuntu:24.04`, started with `--experimental-vector-search-enabled=true` |
| Drivers | TypedbEx `typedb` 0.11.1 (HTTP) and `typedb_grpc` 0.5.1 (gRPC, with the `vector-search` protocol's field 11) |
| Date | 2026-11-14 |

## What is fixed since the alpha

Thank you — each of these was a finding in October:

- A stored vector with a non-finite component is refused: `DVL23`, "cosine
  similarity is undefined for these". In October it was stored as ±Inf and
  then matched every query at every threshold.
- A query vector of zero norm is refused: `COR32`. A stored zero vector
  matches nothing.
- `sort` on a vector-valued variable is refused with a clear message
  (`QUA20`) instead of panicking.
- The similarity binds as a value (`let $e, $s in cosine_similarity_search(...)`),
  is a `double`, and sorts. This was our first ask.
- A query with several `given` rows runs once per row, and its `sort` and
  `limit` span all of them, which is what a per-owner scope set needs.

At 10,000 vectors of 1,024 dimensions, with an owner filter and a status
filter in the same query and the query vector as a `given` value, our recall
measured p50 64 ms and p95 88 ms end to end.

## 1. A search inside `not { }` or `or { }` still panics the server

```typeql
define
  attribute k, value string;
  attribute emb, value vector(4, "float32") @index(hnsw:cosine);
  entity mem, owns k @key, owns emb;

# either of these takes the server process down
given $v: vector(4, "float32");
match $m isa mem, has emb $e;
  not { let $e2, $s in cosine_similarity_search(emb, $v, 0.5); $m has emb $e2; };
select $m;

given $v: vector(4, "float32");
match $m isa mem;
  { let $e, $s in cosine_similarity_search(emb, $v, 0.5); $m has emb $e; } or { $m has k "y"; };
select $m;
```

Expected: an answer, or a query error. Got: the HTTP connection closes
without a response, and the process exits:

```
ERROR common/logger/log_panic.rs:101: A panic occurred
  panic.payload="Expected value annotation"
  panic.location="compiler/annotation/pipeline.rs:382:77"
```

A read-only client can send either query, and the panic takes every database
on the server down with it. Until it is fixed we keep searches in a query's
top conjunction and express alternatives as several `given` rows. A
negation over a relation *beside* a search works.

## 2. `update` of a `@card(0..1)` vector attribute adds a value

```typeql
define
  attribute k, value string;
  attribute name, value string;
  attribute emb, value vector(2, "float32") @index(hnsw:cosine);
  entity n, owns k @key, owns name @card(0..1), owns emb @card(0..1);

insert $x isa n, has k "a", has name "one", has emb vector([1.0, 0.0], "float32");

match $x isa n, has k "a"; update $x has name "two";                              # ok: replaced
match $x isa n, has k "a"; update $x has emb vector([0.0, 1.0], "float32");      # fails
```

Expected: the vector is replaced, as the string is. Got, at commit:

```
[CNT5] Constraint '@card(0..1)' has been violated: found 2 instances.
[DVL10] Instance [...] of type 'n' has an attribute ownership constraint violation
        for attribute ownership of type 'emb'.
```

The `update` added the new value beside the old one. The workaround is to
delete the old value and insert the new one in one transaction.

## 3. A small ask: say why a vector attribute needs an index

```typeql
define attribute plain, value vector(2, "float32");   # SVL63
```

`SVL63` says the attribute "must declare an index annotation". That is a
reasonable rule. It would help to know whether it is permanent, because
some attributes are vectors that are never searched (a stored centroid, a
cached feature). Today such an attribute pays for an index it never uses.
