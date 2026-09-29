---
name: typeql-3
description: Correct TypeQL for TypeDB 3.x where it differs from what a reader expects — TypeDB 2.x forms that 3.x rejects, the error codes 3.x answers with and what each really means, and the annotations, literals and stage rules that are easy to get wrong. Use when a TypeQL query or define is rejected, when a TypeDB error code such as TQL0, SYR1, SYR9, INF2, DEX31, REX3, SVL50, SVL51, LIT255 or CNT9 needs explaining, when a TypeDB schema is being written or migrated, or when code carries TypeDB 2.x habits such as sub entity, get, rule or a trailing count.
---

# TypeQL 3, where it surprises people

This is not a TypeQL tutorial — it is the set of things that are wrong in code
written from memory or from TypeDB 2.x, and the error codes 3.x answers with.

**Everything here was run against TypeDB CE 3.12.1**; every code and message is
what that server returned, not what seemed likely. Two of these were wrong when
first written down and were corrected by running them.

For the language as a whole see <https://typedb.com/docs/typeql/>. For the Elixir
driver, use the `typedb-elixir-driver` skill.

## The declaration form, and the error that hides it

3.x declares a type by its **kind**, then its constraints:

```typeql
define
  attribute name, value string;
  entity person, owns name @key, plays employment:employee;
  entity company, owns name @key, plays employment:employer;
  relation employment, relates employee, relates employer;
  entity dog sub animal;          # `sub` is for a subtype of a named type
```

`sub` still exists, for a subtype: `entity dog sub animal`, never
`dog sub entity`.

**This is the trap that costs the most time.** The 2.x form does not fail as a
syntax error:

```
define dog sub entity, owns name;
  →  400 SYR1 The type 'dog' was not found.
```

3.x reads `dog sub entity` as constraining an existing type called `dog`, so it
reports a **missing type** rather than bad syntax. If a `define` says the type you
are defining was not found, the declaration is 2.x — not the ordering, not the
database, not the server version.

A role must be declared by its relation. `plays employment:employee` with no
`relation employment, relates employee` is
`400 SYR9 The role type 'employment:employee' was not found`.

## Everything else 2.x got away with

Every row measured on 3.12.1:

| 2.x | 3.12.1 answers | 3.x form |
| --- | --- | --- |
| `define dog sub entity, …` | `400 SYR1 The type 'dog' was not found` | `define entity dog, …` |
| `define nickname sub attribute, value string;` | `400 SYR1 The type 'nickname' was not found` | `define attribute nickname, value string;` |
| `match …; get $n;` | `400 TQL0` syntax error | `select $n;` |
| `match $p isa person; count;` | `400 TQL0` syntax error | `reduce $n = count;` |
| `fetch $p: name;` | `400 TQL0` syntax error | `fetch { "name": $p.name };` |
| `rule adult: when { … } then { … };` | `400 TQL0` syntax error | a `fun` (below) |
| `$next = $a + 1;` | `400 TQL0` syntax error | `let $next = $a + 1;` |

The 2.x relation pattern `$e ($role: $p) isa employment;` still parses — but with
a role *variable* it matches **every** role player, not one role. Prefer
`links` with named roles: `$e isa employment, links (employee: $p);`.

## Functions, which replaced rules

```typeql
define
  fun colleagues_of($p: person) -> { person }:
    match
      $e isa employment, links (employee: $p, employer: $c);
      $e2 isa employment, links (employee: $q, employer: $c);
      not { $q is $p; };
    return { $q };

  fun oldest_age() -> integer:
    match $x isa person, has age $a;
    return max($a);
```

`-> { person }` is a stream and `return { $q };` yields it; a single value
declares its type bare and returns an aggregate or `return first $n;`. Calling
differs by kind — `let … in` for a stream, `let … =` for a single value:

```typeql
match $p isa person; let $q in colleagues_of($p); select $q;
match let $m = oldest_age(); select $m;
```

## Annotations, including one that does not work

Verified working: `@key`, `@unique`, `@card(1..3)`, `@card(0..)`, `@abstract`,
`@independent`, `@values("red", "green")`, `@range(0..100)`,
`@regex("^[A-Z]{3}$")`.

**`@subkey` is not implemented in 3.12.1.** It parses, then fails the whole
`define` with `400 LIT255 Unimplemented 'Subkey'`. Use `@key` on a single
attribute, or model the composite key as its own attribute.

**Reserved keywords cannot be identifiers.** `first`, `last` and `match` are
reserved and fail with `400 DEX31`; `value` and `nickname` are fine. An attribute
called `first` is a schema that will not load — use `first_name`.

A role declared `relates element[]` holds an **ordered list** rather than a set:
`relation ordering, relates element[];`.

## Literals that are not guessable

| value type | literal |
| --- | --- |
| `decimal` | `12.345dec` — the `dec` suffix is part of the literal |
| `date` | `2024-03-01` |
| `datetime` | `2024-03-01T12:30:00` |
| `datetime-tz` | `2024-03-01T12:30:00+02:00` or `2024-03-01T12:30:00 Europe/Berlin` |
| `duration` | `P1Y2M3DT4H5M6S` |

A user-declared `struct` is also a value type:

```typeql
define
  struct coords: lat value double, lon value double;
  attribute where, value coords;
```

## Stage rules worth knowing

**`fetch` cannot be paged.** `offset` after a `fetch` is `400 TQL0`. Page the
`match` — `sort`, `offset`, `limit` — and keep the `fetch` last.

**A `fetch` subquery must end in its own `fetch`.** `[ match …; select $c; ]`
fails with `400 FER20 … no fetch found`. This works:

```typeql
match $p isa person;
fetch {
  "name": $p.name,
  "tags": [ $p.tag ],
  "everything": { $p.* },
  "employers": [ match $e isa employment, links (employee: $p, employer: $c); fetch { "n": $c.name }; ]
};
```

`{ $p.* }` takes every attribute. `distinct` is its own trailing stage:
`select $n; distinct;`.

## `put` is not an upsert

`put` matches on the **whole** pattern, not on the identifying part of it.
Measured against an existing Alice aged 30:

```typeql
put $p isa person, has name "Alice", has age 30;   # matches; inserts nothing
put $p isa person, has name "Alice", has age 31;   # 400 CNT9
```

The second does not update her age. It tries to insert a *new* person, and `@key`
on `name` rejects it. Without a `@key` it would silently insert a duplicate. So
`put` the identifying attributes only, and set the rest with `update`:

```typeql
put $p isa person, has name "Alice";
match $p isa person, has name "Alice", has age $a;
update $p has age 31;
```

`delete $p;` removes the instance; `delete has $a of $p;` removes one ownership.

## Migrating a schema that has data

`redefine` must change something and cannot change a value type once instances
exist:

```
redefine attribute age, value integer;   # unchanged →  400 REX3 Nothing was redefined
redefine attribute age, value double;    # with data →  400 SVL50 Cannot change value type
undefine owns score from person;         # with data →  400 SVL51 Cannot unset 'owns score'
```

So a value-type migration is: move the data out of the way, `undefine`, `define`,
move it back.

## The error codes

| code | what it actually means |
| --- | --- |
| `SYR1` | a type in the query does not exist — **see the trap above before anything else** |
| `SYR9` | a role type does not exist; its relation does not `relates` it |
| `INF2` | `Type label 'x' not found` while compiling — the schema lacks it |
| `TQL0` | TypeQL syntax error; the message points at the token |
| `DEX31` | a reserved keyword used as an identifier |
| `LIT255` | an unimplemented feature, e.g. `@subkey` |
| `REX3` | `Nothing was redefined` — the `redefine` changed nothing |
| `SVL50` | cannot change a value type while instances exist |
| `SVL51` | cannot `undefine owns` while instances own it |
| `CNT9` | a `@key` or `@unique` violation, raised on the `insert`, not at commit |
| `FER20` | a `fetch` subquery with no `fetch` in it |
| `QEX21` | a `given` stage with no rows supplied |

## Checking a query without running it

TypeDB ships `typeql-check`; the `typedb` Elixir package wraps it as
`mix typedb.check`, which walks a project and checks the TypeQL in its strings
and `.tql` files. Install it as
[the TypeDB docs describe](https://typedb.com/docs/home/install/typeql-check/).
