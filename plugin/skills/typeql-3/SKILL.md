---
name: typeql-3
description: Write or fix TypeQL for TypeDB 3.x — schemas (entity, relation, attribute, owns, plays, relates, annotations), data queries (match, insert, put, update, delete, select, fetch, reduce, sort), and functions. Use when a query is being written for TypeDB, when a TypeDB schema is being designed, when TypeQL returns a syntax or type error, or when code carries TypeDB 2.x habits that 3.x rejects.
---

# TypeQL 3

TypeQL 3 is not TypeDB 2.x's language with additions — several 2.x forms were
removed, and one of them fails with an error that names the wrong problem. Read
*What 2.x habits break* before writing a schema.

Everything on this page was run against **TypeDB CE 3.12.1** and reports what
that server answered. Where a form fails, the real error code is given.

## A schema

A type is declared by its kind, then its constraints. There is no `sub entity`.

```typeql
define
  attribute name, value string;
  attribute age, value integer;
  attribute since, value datetime;

  entity person,
    owns name @key,
    owns age,
    plays employment:employee;

  entity company,
    owns name @key,
    plays employment:employer;

  relation employment,
    relates employee,
    relates employer,
    owns since;
```

`plays` names a role as `relation_type:role`. A relation must `relates` each of
its roles; a role that nothing `relates` does not exist.

### Value types

`string`, `integer`, `double`, `decimal`, `boolean`, `date`, `datetime`,
`datetime-tz`, `duration`, and a user-declared `struct`.

```typeql
define
  struct coords:
    lat value double,
    lon value double;
  attribute where, value coords;
```

### Subtypes and abstract types

```typeql
define
  entity animal @abstract, owns name;
  entity dog sub animal;
```

`sub` still exists — for a *subtype* of a named type. It is `entity dog sub
animal`, never `dog sub entity`.

### Annotations

Verified working on 3.12.1: `@key`, `@unique`, `@card(1..3)`, `@card(0..)`,
`@abstract`, `@independent`, `@values("red", "green")`, `@range(0..100)`,
`@regex("^[A-Z]{3}$")`.

```typeql
define
  attribute email, value string;
  attribute tag, value string;
  attribute pct, value integer @range(0..100);
  entity user,
    owns email @unique,
    owns tag @card(0..);
```

**`@subkey` is not implemented in 3.12.1.** It parses and then fails the whole
`define` with `400 LIT255 Unimplemented 'Subkey'`. Use `@key` on one attribute,
or model the composite key as its own attribute.

### Ordered role players

A role declared `relates element[]` holds an ordered list rather than a set.

```typeql
define
  entity item, owns name @key, plays ordering:element;
  relation ordering, relates element[];
```

## Data

```typeql
insert
  $alice isa person, has name "Alice", has age 30;
  $acme isa company, has name "Acme";
  (employee: $alice, employer: $acme) isa employment, has since 2020-01-01T00:00:00;
```

### Literals

Each of these was inserted and read back on 3.12.1:

| value type | literal |
| --- | --- |
| `string` | `"Alice"` |
| `integer` | `7` |
| `double` | `1.5` |
| `decimal` | `12.345dec` — the `dec` suffix is part of the literal |
| `boolean` | `true` |
| `date` | `2024-03-01` |
| `datetime` | `2024-03-01T12:30:00` |
| `datetime-tz` | `2024-03-01T12:30:00+02:00` or `2024-03-01T12:30:00 Europe/Berlin` |
| `duration` | `P1Y2M3DT4H5M6S` |

### Reading

```typeql
match $p isa person, has name $n, has age $a;
select $n, $a;
sort $n desc;
offset 0;
limit 10;
```

`select` is the projection. **`get` does not exist in 3.x** and is a syntax
error. `distinct` is its own trailing stage: `select $n; distinct;`.

Matching relations, most precise first:

```typeql
match $e isa employment, links (employee: $p, employer: $c); select $p, $c;
match ($p, $c) isa employment; select $p, $c;
```

The 2.x form `$e ($role: $p) isa employment;` still parses, but with a role
*variable* it matches every role player rather than one role — on the schema
above it returns both the employee and the employer. Prefer `links` with named
roles.

Patterns: `not { … }`, `{ … } or { … }`, `try { … }` with `require $x;`,
comparisons (`has age >= 5`), `like "^Al.*"` for a regex, `contains "li"` for a
substring, `isa!` for an exact type, `$x is $y` for identity.

Arithmetic needs `let`:

```typeql
match $p isa person, has age $a;
let $next = $a + 1;
select $next;
```

A bare `$next = $a + 1;` is a syntax error.

### Aggregating

`reduce` is a stage, and it names its outputs:

```typeql
match $p isa person; reduce $n = count;
match $p isa person, has age $a; reduce $total = sum($a), $oldest = max($a);
match $p isa person, has age $a; reduce $n = count groupby $a;
```

A trailing `count;` — the 2.x form — is a syntax error.

### Documents, with `fetch`

`fetch` returns JSON-shaped documents rather than rows of concepts:

```typeql
match $p isa person;
fetch {
  "name": $p.name,
  "age": $p.age,
  "tags": [ $p.tag ],
  "everything": { $p.* },
  "employers": [ match $e isa employment, links (employee: $p, employer: $c); fetch { "n": $c.name }; ]
};
```

Three things that are easy to get wrong, all measured:

- A subquery in `[ … ]` must end in its own `fetch`. `[ match …; select $c; ]`
  fails with `400 FER20 … no fetch found`.
- `{ $p.* }` is how you take every attribute of `$p`.
- **`fetch` cannot be paged.** `offset` after a `fetch` is `400 TQL0`. Page the
  `match` and `fetch` inside it, or use `select` and page that.

### Writing

```typeql
put $p isa person, has name "Bob", has age 41;

match $p isa person, has name "Bob", has age $a;
update $p has age 42;

match $p isa person, has name "Bob";
delete $p;

match $p isa person, has name "Alice", has age $a;
delete has $a of $p;
```

`put` inserts only when the pattern does not already match, and it matches on the
**whole** pattern, not on the identifying part of it. Measured against an
existing Alice aged 30:

```typeql
put $p isa person, has name "Alice", has age 30;   # matches; inserts nothing
put $p isa person, has name "Alice", has age 31;   # 400 CNT9
```

The second one does not update the age and does not quietly duplicate her
either: it tries to insert a new person, and `@key` on `name` rejects it with
`400 CNT9`. Without a `@key` the same query would insert a second person. So
`put` is an upsert only for rows you never change — put the identifying
attributes, and set everything else with `update`.

`delete $p;` removes the instance. `delete has $a of $p;` removes one ownership.

## Functions

Functions replace 2.x rules, which no longer parse.

```typeql
define
  fun colleagues_of($p: person) -> { person }:
    match
      $e isa employment, links (employee: $p, employer: $c);
      $e2 isa employment, links (employee: $q, employer: $c);
      not { $q is $p; };
    return { $q };
```

`-> { person }` is a stream return and `return { $q };` yields it. A single-value
function declares the type bare, and returns an aggregate or a `first`:

```typeql
define
  fun oldest_age() -> integer:
    match $x isa person, has age $a;
    return max($a);

  fun name_of($p: person) -> name:
    match $p has name $n;
    return first $n;
```

Call a stream function with `let … in`, and a single-value one with `let … =`:

```typeql
match $p isa person, has name "Alice";
let $q in colleagues_of($p);
select $q;

match let $m = oldest_age();
select $m;
```

## What 2.x habits break

Every row was run on 3.12.1. The first is the one that costs the most time,
because the error names the wrong thing.

| 2.x | what 3.12.1 answers | 3.x form |
| --- | --- | --- |
| `define dog sub entity, owns name;` | `400 SYR1 The type 'dog' was not found` | `define entity dog, owns name;` |
| `define nickname sub attribute, value string;` | `400 SYR1 The type 'nickname' was not found` | `define attribute nickname, value string;` |
| `match …; get $n;` | `400 TQL0` syntax error | `select $n;` |
| `match $p isa person; count;` | `400 TQL0` syntax error | `reduce $n = count;` |
| `fetch $p: name;` | `400 TQL0` syntax error | `fetch { "name": $p.name };` |
| `rule adult: when { … } then { … };` | `400 TQL0` syntax error | a `fun` |
| `$next = $a + 1;` | `400 TQL0` syntax error | `let $next = $a + 1;` |

`SYR1 The type 'dog' was not found` is the trap: 3.x reads `dog sub entity` as
constraining an existing type `dog`, so it reports a missing type rather than
bad syntax. If a `define` says a type you are defining was not found, you wrote
2.x.

## Other errors worth recognising

| code | what happened |
| --- | --- |
| `SYR1` | a type in the query does not exist (see the trap above) |
| `INF2` | `Type label 'x' not found` while compiling — the schema lacks it |
| `TQL0` | TypeQL syntax error; the message points at the token |
| `DEX31` | a reserved keyword used as an identifier |
| `REX3` | `Nothing was redefined` — a `redefine` that changes nothing fails |
| `SVL50` | cannot change a value type while instances exist |
| `SVL51` | cannot `undefine owns` while instances own it |
| `CNT9` | a `@key` or `@unique` violation, raised on the `insert` |

**Reserved keywords cannot be identifiers.** `first`, `last` and `match` are
reserved and fail with `400 DEX31`; `value` and `nickname` are accepted. If a
`define` rejects an attribute name, rename it (`first_name`, `family_name`).

`redefine` must change something, and cannot change a value type once instances
exist — so a migration is `undefine` plus `define`, on a database whose data you
have moved out of the way first.

## Checking a query without running it

TypeDB ships `typeql-check`, a syntax checker. The `typedb` Elixir package wraps
it as `mix typedb.check`, which walks a project and checks the TypeQL it finds in
strings and `.tql` files. Install it as
[the TypeDB docs describe](https://typedb.com/docs/home/install/typeql-check/).

## Reference

- TypeQL: <https://typedb.com/docs/typeql/>
- TypeDB 3 documentation: <https://typedb.com/docs/>
