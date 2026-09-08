# Which database, per tier, per cloud

Written 2026-09-07, because "is Postgres still the right call, or is that just
an old decision we are stuck with" is a fair question that had no written
answer. This is the answer, the evidence behind it, and the specific things
that would change it.

**Summary.** Keep PostgreSQL. The reason is stronger than history. The
opportunity worth taking is not the engine, it is the managed *service* on AWS:
the HA and autoscale tiers use plain RDS where Aurora PostgreSQL would be
strictly better, and that is a module change with no application change at all.

---

## What is deployed today

| Tier | Azure | AWS |
|---|---|---|
| `single-vm` | none — the image's own embedded Postgres | same |
| `ha-hot-hot` | Flexible Server, VNet-injected | `aws_db_instance`, `multi_az = true` |
| `unlimited-scale` | Flexible Server + `db_replica_count` read replicas | `aws_db_instance` primary + replicas |

All three tiers also accept `db_mode = "vm"` (self-managed Postgres on a
dedicated VM) and `db_mode = "external"` (a server the customer already runs,
where we provision no database at all).

---

## Why not NoSQL, and why that is not a legacy answer

This was checked against the application rather than assumed:

- **67 tables** in `db/db_postgres/migrations/`.
- **82 query sites** using joins or aggregates in `models/`.
- **1** JSONB column in the entire schema.
- Real transactions in report subscriptions and campaign data.

The shape is normalised and relational, and the reporting is join-heavy by
nature. RBAC is a textbook many-to-many (`roles` ↔ `role_permissions` ↔
`permissions`); campaign reporting aggregates `events` against `results`
against `targets` against `groups`. One JSONB column in 67 tables says the data
is not document-shaped and nobody has been fighting the relational model.

So Cosmos DB (any API), DynamoDB, Azure SQL and the rest are not a migration,
they are a rewrite of the data layer plus every report. And the destination is
worse for this workload, not better: the queries that matter are exactly the
ones document stores make hard.

`models/models.go` refusing any engine but `postgres` is a *consequence* of
that, not the reason for it.

### Cosmos DB for PostgreSQL (Citus) — the one that is not silly

It speaks the Postgres wire protocol, so it would work without an application
change. It solves horizontal *sharding* of writes beyond what one node can
take. That is not the problem we have: a single Flexible Server handles SAT's
write volume with room to spare, and the minimum useful footprint is a
coordinator plus two worker nodes, so it costs considerably more.

Revisit only if a single primary genuinely runs out of write capacity. Read
capacity is not the trigger — replicas already cover that.

---

## The strongest argument for one engine everywhere

`instancemigrate` moves a customer from a single VM to an HA pair with
`pg_dump` and `psql`, over the product's own API, because **both ends are
Postgres**. `./go.sh migrate-data` in the deployment bundles is that path.

If `single-vm` used SQLite and the HA tier used Postgres, growing a pilot into
production would need a dialect converter, and the conversion would be the
thing that breaks. SQLite and MySQL were both retired for this reason, and
`models/postgres_query_smoke_test.go` exists specifically because
dialect-divergent SQL (`strftime`, `BOOL=1`, MySQL backticks) had already
shipped bugs.

One engine across every tier means one dialect, one migration tool, one backup
format, one restore drill. That is worth more than any per-tier optimisation on
offer.

---

## The thing actually worth changing: Aurora on AWS

`modules/ha-hot-hot/aws` and `modules/unlimited-scale/aws` use
`aws_db_instance` — plain RDS Postgres with `multi_az = true` and separate
replica instances. Aurora PostgreSQL is wire-compatible, so **the application
does not change**; only the Terraform resource does.

What it buys, in the order it matters here:

1. **Failover.** Aurora typically promotes in about 30 seconds against roughly
   60–120 for RDS Multi-AZ. On a tier whose entire premise is not having an
   outage, that is the headline number.
2. **Read replicas share storage.** `aws_db_instance.replica` replicates into
   its own volume and therefore carries replication lag. Aurora readers read
   the same storage, which suits the autoscale tier's read fan-out far better.
3. **Serverless v2.** A phishing-simulation platform is spiky by definition:
   a campaign bursts, then the instance idles for days. Fixed instance classes
   pay for the peak continuously; Serverless v2 scales capacity and can be
   materially cheaper for that profile. This is the option most likely to
   reduce the bill rather than raise it.

The cost note has to be honest: per instance-hour Aurora is roughly 20% more
than the equivalent RDS class. Provisioned Aurora on a steady 24/7 load is
therefore *more* expensive. The saving comes from Serverless v2 on a spiky
load, so the evaluation has to measure the real duty cycle before claiming a
number.

**Azure has no equivalent worth chasing.** Flexible Server is the correct
managed Postgres there, and Cosmos DB for PostgreSQL is the Citus case above.
The Azure-side database work that pays off is the entitlement for
zone-redundant HA, not a different service.

---

## The cheapest lever is not the engine

Before optimising which database, note that `db_mode` already removes it:

- `external` provisions no database at all. Largest single saving available.
- `vm` runs self-managed Postgres on a dedicated VM: cheaper infrastructure,
  and the VM does not carry the Marketplace per-vCPU meter.

Both hand availability, backups and point-in-time restore to the customer, so
neither belongs in a deployment sold on HA. They exist for customers who
already run Postgres well.

One thing NOT to do, having been asked: do not co-locate the database on one of
the two application VMs. It is cheaper than every option above and it makes
that one VM a single point of failure for the whole service. Keeping the
database off both app nodes is a larger fault-tolerance gain than the database
standby itself.

---

## Revisit triggers

Concrete, so this does not get re-litigated on instinct:

- **Aurora spike on AWS.** Worth doing. Measure duty cycle first, then compare
  Serverless v2 against the current instance class on real campaign traffic.
  The measurement is below, because "measure first" without a method is how a
  spike turns into an argument.
- **A single primary runs out of WRITE capacity.** Then, and only then, Cosmos
  DB for PostgreSQL / Citus becomes the conversation. Read pressure is not this
  trigger.
- **The schema stops being relational.** If JSONB columns go from 1 to dozens
  and reporting moves to application-side assembly, the premise here has
  changed and this document is stale.
- **A customer mandates a specific engine.** `db_mode = "external"` already
  covers "we run our own Postgres". A non-Postgres mandate is a rewrite, and
  should be priced as one rather than absorbed.

---

## Appendix — how to measure the duty cycle before quoting Aurora

Serverless v2 is the only variant that can be *cheaper*: provisioned Aurora is
roughly 20% more per instance-hour than the equivalent RDS class, so on a steady
load it loses. The whole question is therefore how spiky the real load is, and
that is measurable from the deployment that already exists — no Aurora needed to
decide whether to move to Aurora.

Pull at least **four weeks** from CloudWatch for the existing
`aws_db_instance`, covering at least two real campaigns. Anything shorter
measures the gap between campaigns and flatters the case:

```
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value=<instance-id> \
  --start-time  "$(date -u -d '28 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 --statistics Average Maximum --output table
```

Repeat for `DatabaseConnections`, `ReadIOPS` and `WriteIOPS`. Together those
say how much of the provisioned instance is actually used, and when.

What decides it:

- **Ratio of peak to median.** A campaign burst against a mostly-idle baseline
  is the profile Serverless v2 is for. A flat line is not, and the answer is
  then "stay on RDS" rather than "Aurora is expensive".
- **Duration of the peaks.** Serverless v2 bills the capacity it scales to, for
  as long as it holds it. Long plateaus erode the saving; short bursts do not.
- **The floor.** Serverless v2 has a minimum capacity that bills continuously,
  so an idle deployment is not free. A low duty cycle wins only if the floor is
  below what the current instance class costs at idle — which is a price-list
  question, not one this document can answer.

Do NOT convert any of this into a saving using numbers from this file. Take the
ACU and instance-class prices from the current AWS price list for the target
region on the day of the comparison, and state the measured duty cycle alongside
the figure so the next reader can tell whether it still applies.

Two things worth knowing before the spike starts, because they change the shape
of the work rather than the number:

- Aurora is wire-compatible, so **no application change** — `models/` and the
  DSN in `/etc/hailbytes-sat/env` are untouched. The change is confined to
  `modules/ha-hot-hot/aws` and `modules/unlimited-scale/aws`.
- Moving an existing deployment is a **migration, not an in-place edit**:
  `aws_db_instance` and `aws_rds_cluster` are different resources, so Terraform
  plans a destroy and create. Any customer already running on RDS needs a
  snapshot-restore path and a maintenance window, and that cost belongs in the
  spike's estimate rather than being discovered during it.
