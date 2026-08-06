# Quickstart

Two ways in, depending on how much you want to decide yourself.

## Guided (recommended for a first deployment)

Run this in **AWS CloudShell** or **Azure Cloud Shell** — both already have
`terraform`, `git` and their own CLI installed, so there is nothing to set up:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HailBytes/hailbytes-terraform-modules/main/quickstart/deploy.sh)
```

[`deploy.sh`](deploy.sh) detects which cloud it is running in, then walks you
through:

1. **Prerequisites** — confirms the tools and that you are signed in, and shows
   which subscription or account you are about to deploy into.
2. **Marketplace subscription** — checks whether the product image is actually
   visible to your account in your region, and links the listing if it isn't.
   An unsubscribed offer is the single most common reason a first `apply` fails.
3. **Deployment shape** — product, tier, region, database backend, frontend.
4. **Plan, then apply** — writes a `main.tf` you own and can keep in version
   control, runs `terraform plan`, shows it to you, and applies only after you
   type `APPLY` in full.

**Nothing is created until you confirm a plan.** If you answer no at the end,
the generated configuration stays in `~/hailbytes-deploy` and you can run
Terraform there yourself.

### It warns you before anything expensive

Every question that materially changes the bill prints a `COST IMPACT` block
with real figures and waits for you to acknowledge it. The six that matter
most:

| Choice | Why it's flagged |
|---|---|
| HA tier | ~2.8× the all-in cost of a single VM — not 2×, because the zone-redundant database bills 2× compute *and* 2× storage for the standby |
| Autoscale tier | Every scaled-out instance meters at $0.24/vCPU-hour, and the ceiling is whatever you set `max` to |
| Read replicas | Each is a full database server — ~$3,858/year each, and a 3-instance deployment rarely needs any |
| `db_mode` = self-managed VM | *Cheaper infrastructure and cheaper overall* — the DB VM boots plain Canonical Ubuntu with apt-installed PostgreSQL, **not** the HailBytes Marketplace image, so it does **not** carry the meter. What you give up is managed backups, point-in-time restore and automatic failover |
| `db_mode` = external | Removes the database from your cloud bill entirely, but availability, backups and PITR become yours |
| Application Gateway | ~$187/mo (or ~$336 with WAF) — 10–18× the load balancer it sits in front of, which stays in the topology |

It also tells you the things that look like savings and aren't: `SameZone` HA
costs the same as `ZoneRedundant`, and Flexible Server storage can grow but
never shrink, so day-one over-provisioning is permanent.

### It warns you about two things that aren't costs

**The Key Vault 30-day trap.** Azure Key Vault names are globally unique, and
the vault is created with purge protection and a 30-day soft-delete window that
cannot be waived (a disk encryption set requires purge protection). Destroy a
deployment and re-create it under the same name inside 30 days and the apply
fails, with no force-purge available. The wizard asks whether this is a
throwaway PoC and generates a unique vault name if so — which is free, and the
alternative is waiting out a month.

**Azure Cache for Redis is being retired.** Basic/Standard/Premium on
2028-09-30, Enterprise on 2027-03-31. The wizard says so before it provisions
one, and specifically steers away from buying the Premium tier for zone
redundancy: the successor, Azure Managed Redis, is zone-redundant by default and
costs about a quarter as much.

### Database options

The wizard asks how you want the database provisioned, because this is the
largest cost line in every HA and autoscale deployment and the answer depends
on what the customer already runs:

| Option | What you get | What you own |
|---|---|---|
| **Managed** (`flexible_server` / `rds`) — default | Zone-redundant, automated backups, point-in-time restore, automatic failover | Nothing; the cloud runs it |
| **Self-managed VM** (`vm` / `ec2`) | A dedicated instance running PostgreSQL 16 | Backups, patching, availability. Carries the per-vCPU meter. |
| **External** | Nothing — we connect to your server | Everything about the database. TLS is enforced; the pre-patch routine will not snapshot a server we don't own. |

## Manual

If you would rather read the Terraform first, [`azure-ha/`](azure-ha) is a
complete root config for the Azure HA tier — networking included — that you can
copy, edit and apply. Per-tier module documentation lives under
[`../modules/`](../modules).

## Testing

The wizard is interactive, but its pure logic is unit-tested and runs in CI:

```bash
bash quickstart/tests/deploy_test.sh
```

That covers cloud detection, the tier → module-name mapping (a typo there would
point a customer at a module that doesn't exist), the marketplace identifiers
matching the Terraform modules, the apply gate requiring the literal word
`APPLY`, external-DB password file handling, and an assertion that **every**
billing-relevant branch emits a cost warning — so a future contributor can't
add an expensive option without one.

`deploy.sh` can be sourced for testing without running the wizard:

```bash
HAILBYTES_WIZARD_LIB=1 . quickstart/deploy.sh
```

## Related

- [`../AZURE_COST_SHAPES.md`](../AZURE_COST_SHAPES.md) — the verified figures the cost warnings are drawn from, plus the levers that reduce them
- [`../COST_SHAPES.md`](../COST_SHAPES.md) — AWS shapes and the channel SKU mapping
- [`../docs/AZURE_HA_PARITY_AUDIT.md`](../docs/AZURE_HA_PARITY_AUDIT.md) — what the Azure topology does and does not deliver today
- [`../docs/AZURE_PATCHING_AND_MIGRATION.md`](../docs/AZURE_PATCHING_AND_MIGRATION.md) — read before your first image update
