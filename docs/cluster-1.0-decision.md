# Should `typedb` 1.0 support several servers?

**Recommendation: out for 1.0.** One connection keeps pointing at one server. The
workaround is a load balancer or one supervised connection per node, and
`README.md`'s *Limitations* says so plainly.

This is a decision record, not a plan. Nothing here builds failover.

*Written 2026-09-29 against TypeDB 3.12.1. Sources are marked: **measured** here,
or **documented** by TypeDB with the page named.*

## What prompted the question

`TypeDB.Server.servers/1` returns cluster membership and nothing in the driver
consumes it. A connection takes one `:url`. That looks like an unfinished
feature, so it is worth settling before 1.0 freezes the surface — either build
it, or say why not and leave the door open.

## What TypeDB 3.x actually offers

**Community Edition is single-node.** Clustering is available through TypeDB
Cloud and TypeDB Enterprise; CE supports single-node deployments only
(documented, [Compare TypeDB editions](https://typedb.com/editions)).

**Clustering in 3.x is alpha.** The reference page says clustering "is being
actively developed and is currently on the alpha stage", that features "will be
improved and can be changed between releases", and — in as many words — "Please
do not use the experimental version of clustered TypeDB in production"
(documented, [Clustered TypeDB
(Experimental)](https://typedb.com/docs/reference/typedb-cluster/)). Replication
is Raft-based, with a primary replica for strongly consistent operations and
secondaries for eventually consistent idempotent ones.

**The cluster features live in the gRPC drivers, not in the HTTP API.** This is
the decisive one. TypeDB's own page on drivers in a cluster describes replica
discovery, routing schema transactions to the primary, and automatic failover as
things the **gRPC** drivers do — and then says: *"Alternatively, the TypeDB HTTP
endpoint and drivers are unchanged and can be used the usual way by explicitly
choosing a specific replica to send requests to"* (documented, [Drivers in
clustered TypeDB](https://typedb.com/docs/reference/typedb-cluster/drivers/)).

So the HTTP API — which is what this package speaks — offers no cluster
protocol. There is no redirect, no "you are talking to a secondary" signal, and
no documented way to ask which replica is primary over HTTP.

**And on CE there is not even an address to route to.** Measured against 3.12.1:

```elixir
TypeDB.Server.servers(conn)
#=> {:ok, [%{"address" => nil}]}
```

One entry, and its `address` is `nil`. The endpoint the driver already calls
returns nothing a router could use.

## What "supporting several servers" would actually take

Not one feature. At least five, each with its own failure modes:

1. **Membership and addresses.** Accept `:urls`, or discover peers from one.
   Over HTTP there is no discovery worth the name — see the `nil` above — so it
   would be a static list the user maintains, which is a load balancer with
   extra steps.
2. **Which node takes writes.** Raft has a primary. Without a protocol-level way
   to learn which node that is, or to be redirected, the driver would have to
   guess, try, and interpret failures — and a write that fails *after* the
   server received it cannot be retried safely, which this driver already
   refuses to do for exactly this reason.
3. **Reads elsewhere.** Secondaries serve eventually consistent reads. Routing
   reads to them is a *correctness* choice a caller has to make per query, not
   a driver default: "your read may be stale" is not something to turn on for
   everybody.
4. **Reconnect semantics.** What happens to an open transaction when its node
   goes away, whether a token issued by one node is accepted by another, and
   what a partially applied multi-statement transaction means to the caller.
   None of it is specified for HTTP.
5. **Testing it.** Every claim in this driver is checked against a live server,
   which is why the supported TypeDB range is measured rather than assumed. A
   multi-node cluster is Cloud/Enterprise, so CI has nothing to test against.
   Failover that has never survived a real partition is a claim, not a feature.

## The cost

The work is perhaps a week; the cost is not the week. It is:

- **shipping an untestable promise.** Failover is exactly the feature whose bugs
  appear only under the conditions CI cannot create. This repository's rule is
  that a finding is a hypothesis until it has been run — and none of this could
  be run;
- **against an alpha.** TypeDB says not to use clustered 3.x in production and
  that it will change between releases. A 1.0 surface built on it would be
  frozen against a moving target;
- **in the wrong package.** The cluster protocol is gRPC. If NoeticEcho wants
  cluster support, it belongs in `typedb_grpc`, which already speaks that
  protocol and where TypeDB's own driver semantics can be followed rather than
  invented.

## What a user does instead

A load balancer in front of the cluster, or one supervised connection per node
with the choice made in application code:

```elixir
children = [
  {TypeDB, name: :primary, url: "http://node-1:8000", username: "admin", password: pw},
  {TypeDB, name: :replica, url: "http://node-2:8000", username: "admin", password: pw}
]

TypeDB.query(:primary, "social", "insert …", transaction_type: :write)
TypeDB.query(:replica, "social", "match …", transaction_type: :read)
```

Connections are independent processes with their own pools and tokens, so this
works today and the application keeps the routing decision — which, given point
3 above, is where it belongs.

## Why this does not need a 1.0 slot held open

Adding `:urls` later is **additive**: a new option, with `:url` continuing to
mean what it means. Nothing about the current surface has to be reserved,
deprecated or shaped differently to make room for it. That is what makes "out"
cheap to reverse and "in" expensive to get wrong.

## What would change the answer

- TypeDB's HTTP API gains cluster semantics — a redirect, a primary hint, or a
  `/servers` response with real addresses;
- clustering leaves alpha and CI can run a multi-node cluster to test against;
- or the demand arrives with a user who has a cluster and can tell us what broke.

Until one of those, one connection is one server, and the README says so.
