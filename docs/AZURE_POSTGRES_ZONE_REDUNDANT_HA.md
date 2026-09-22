# Azure Postgres: getting zone-redundant HA when Azure refuses it

For the Azure HA tier (`asm-azure-ha`, `sat-azure-ha`) when the database create
fails with `MultiAzHaIsOfferRestricted`. Covers getting a working deployment
now, filing the support request, what Microsoft answers, and adding the standby
later without rebuilding anything.

## The failure

About fifteen minutes into the first apply:

```
Status: "MultiAzHaIsOfferRestricted"
Message: "Multi-Zone HA is not supported in this region. Please choose a
different region. For exceptions to this rule please open a support request."
```

## What it actually means

Zone-redundant Flexible Server is granted **per subscription, per region**,
through a quota request, and Microsoft grants it only where the region has
**zonal capacity** for the service. Two separate things have to be true, and
the error does not say which one failed:

- The subscription has the allocation for that region.
- The region has capacity to give it. This is not the same as the region having
  availability zones. VMs pinned to zones 1 and 2 in the same region prove the
  zones exist; they say nothing about Postgres zonal capacity.

A customer deployment in North Europe (September 2026) hit this. Microsoft's
answer was that the region is **capacity-restricted** for new zone-redundant
Flexible Server deployments, and that the request would stay pending until
capacity is added. So "the region is fine, it is only your subscription" is
**not** a safe thing to tell a customer, and changing region **can** help.
Don't argue the premise with Microsoft in the request.

`terraform plan` can't see either condition. `az postgres flexible-server
list-skus -l <region>` shows what the region's catalogue advertises, not what
capacity your subscription can get.

## Getting a working deployment now

```hcl
db_high_availability_mode = "Disabled"
```

The application VMs stay hot-hot across zones 1 and 2 behind the zone-redundant
address. The database loses its standby, so a zone loss becomes a restore from
backup rather than a failover. The module's `database_has_a_standby` check
warns about this on every plan and apply, so the gap stays visible.

**`SameZone` is not a substitute** when the customer asked for the same HA
level on the database as on the VMs. It puts the standby in the primary's zone:
it covers a server failure, not a zone failure. It bills the same as
`ZoneRedundant` (2x compute, 2x storage). Offer it only if the customer
explicitly wants node-level failover in the meantime.

## Filing the request

Azure portal > **Help + support** > **Create a support request**

| Field | Value |
|---|---|
| Issue type | **Service and subscription limits (quotas)** |
| Quota type | **Azure Database for PostgreSQL flexible server** |
| Subscription | `<subscription-id>` |
| Severity | C, or B if a go-live date is firm |

Filed under *Technical* instead of *Quotas*, it usually gets bounced.

Description, with placeholders filled in:

> **Request: enable zone-redundant high availability for Azure Database for
> PostgreSQL flexible server on this subscription.**
>
> Subscription ID: `<subscription-id>`
> Region: `<region>`
> SKU / tier: `<sku, e.g. GP_Standard_D2ds_v5>`, General Purpose
>
> Creating a flexible server with zone-redundant HA fails with
> `MultiAzHaIsOfferRestricted`: "Multi-Zone HA is not supported in this region.
> For exceptions to this rule please open a support request."
>
> The application tier of this deployment already runs across availability
> zones 1 and 2 in `<region>`. The database is the only single-zone component,
> so a zone loss is a restore from backup rather than a failover. We are asking
> for zone-redundant HA so the database matches the application tier.
>
> We understand the standby is billed as a full secondary instance and accept
> the cost. Please confirm once it is enabled and we will add the standby to
> the existing server.

## What Microsoft answers, and what to reply

If the region is capacity-restricted, they decline for now and offer:

1. Keep the request open with fortnightly updates.
2. Keep it open and update only when it is fulfilled.
3. Close and archive it.

**Choose 2.** It keeps the request's place in the queue. Option 3 starts over.

In the same reply, ask:

> Which regions near `<region>` currently have zone-redundant capacity for
> Azure Database for PostgreSQL Flexible Server?

They suggest another region without naming one. Asking gets the customer a
concrete choice instead of an open-ended wait.

**Escalate outside the queue if you can.** A request on a Basic support plan at
severity C sits in the general queue. Capacity requests routed through the
customer's Microsoft account team or CSP partner usually move faster.

## Before anyone suggests moving region

Check data residency first. Moving region is a rebuild, and for a customer
whose data has to stay in-country (North Europe is Ireland; West Europe is the
Netherlands) it may not be allowed at all. Find that out before pricing a
migration. If moving is off the table, waiting is the only route.

## Adding the standby later

When Microsoft confirms, change one variable and apply:

```hcl
db_high_availability_mode = "ZoneRedundant"
```

This updates the server **in place**. It does not rebuild it:

- Azure allows HA to be enabled on an existing flexible server.
- The module's `high_availability` block is `dynamic` on this variable, so
  `"Disabled"` omits it and any other value adds it. Adding a block is an
  update.
- While HA is off the module pins `zone` beside `vm[0]`. Turning HA on hands
  placement to Azure, and `zone` and `standby_availability_zone` are in the
  server's `ignore_changes`, so that produces no diff.

**Read the plan before applying.** You want the Postgres server as an update,
with a `high_availability` block being added:

```
~ resource "azurerm_postgresql_flexible_server" "main" {
    + high_availability {
        + mode = "ZoneRedundant"
      }
  }
```

**If it says `must be replaced`, stop.** Something else changed with it
(`zone`, `sku_name`, `storage_mb`, the resource group). Replacing that server
means a restore from backup.

During the apply:

- Allow 10 to 20 minutes while Azure builds and syncs the standby.
- A brief failover-style interruption is possible. Do it outside a send window
  or change freeze.
- No credential rotation. Key Vault secrets, connection string and server FQDN
  are unchanged.

Afterwards the `database_has_a_standby` warning stops firing. That's the
confirmation the gap is closed.

Make the change through Terraform, not the portal or CLI. Changing it out of
band leaves the variable at `"Disabled"`, and the next apply proposes removing
the standby.

Sources: [High availability concepts](https://learn.microsoft.com/en-us/azure/postgresql/high-availability/concepts-high-availability),
[Configure high availability](https://learn.microsoft.com/en-us/azure/postgresql/high-availability/how-to-configure-high-availability)
