# Deploying SAT HA from the HailBytes Compute Gallery (test only)

For standing up a two-node SAT stack in the **HailBytes** Azure subscription
from an image we built ourselves, instead of from the published marketplace
listing.

## Read this first

This path is a deliberate, reviewed exception to the rule in
[CLAUDE.md](../CLAUDE.md): *"No modules that deploy from custom-built
AMIs/VHDs."* It exists for exactly one reason.

Four of the fixes that make a two-node deployment work at all are **image-side**
(`hailbytes-sat` #905, #906, #907, #908). None of them can be observed on a real
stack until a VM boots an image that *contains* them, and the published
marketplace image by definition does not yet. Waiting for a marketplace
certification cycle between each iteration would make the feedback loop days
long.

Two things follow, and both matter:

1. **A gallery deployment is not marketplace-metered.** Setting
   `source_image_id` drops the `plan {}` block, which is what marketplace
   billing keys off. That is intentional — it makes this path structurally
   unusable as a way to ship product to a paying customer, rather than merely
   discouraged.
2. **It is therefore not a customer deployment.** Do not use it for a customer
   trial, a POC, or a demo you are billing for. For anything customer-facing,
   use `quickstart/azure-ha`, which deploys the marketplace image.

A reviewer seeing a non-null `source_image_id` outside CI should treat it as a
defect.

## What you need

The Packer build (`hailbytes-sat/.github/workflows/packer-build.yml`) publishes
an image **version** into the gallery on every run. Its defaults:

| Thing | Default |
|---|---|
| Resource group | `rg-hailbytes-sat-images` |
| Gallery | `hailbytes_sat_gallery` |
| Image definition | `hailbytes-sat-ubuntu-2404` |
| Replicated to | `eastus`, `westus`, `westeurope` |

Find the newest version:

```bash
az sig image-version list \
  --resource-group rg-hailbytes-sat-images \
  --gallery-name hailbytes_sat_gallery \
  --gallery-image-definition hailbytes-sat-ubuntu-2404 \
  --query "sort_by([].{version:name, created:publishingProfile.publishedDate}, &created)[-1]" \
  -o table
```

Deploy into a region the version is actually replicated to, or the VM create
fails with an image-not-found that reads like a permissions problem.

## The snippet

```hcl
# Pin an explicit version rather than interpolating "latest": you want to know
# which image a given test result came from.
locals {
  sat_image_version = "1.1447.0" # <- from the az command above

  sat_gallery_image_id = join("/", [
    "/subscriptions/${data.azurerm_client_config.current.subscription_id}",
    "resourceGroups/rg-hailbytes-sat-images",
    "providers/Microsoft.Compute/galleries/hailbytes_sat_gallery",
    "images/hailbytes-sat-ubuntu-2404",
    "versions/${local.sat_image_version}",
  ])
}

data "azurerm_client_config" "current" {}

module "sat_ha" {
  source = "github.com/HailBytes/hailbytes-terraform-modules//modules/sat-azure-ha"

  resource_group_name = azurerm_resource_group.test.name
  location            = "eastus"

  # Networking: compose modules/network/azure rather than hand-building these.
  vm_subnet_id           = module.network.workload_subnet_id
  lb_subnet_id           = module.network.lb_subnet_id
  db_delegated_subnet_id = module.network.db_delegated_subnet_id
  private_dns_zone_id    = module.network.private_dns_zone_id

  vm_size        = "Standard_D8s_v5"
  ssh_public_key = file("~/.ssh/id_ed25519.pub")

  # Your own egress only. The LB's 443 and 80 frontends are the public surface,
  # and this is what bounds them.
  allowed_cidrs = ["${chomp(data.http.my_ip.response_body)}/32"]

  # ---- the test-only part ----
  # Boots our own image instead of the marketplace one. Drops the `plan` block,
  # so this deployment is NOT marketplace-metered. Never set in a customer
  # deployment.
  source_image_id = local.sat_gallery_image_id

  # Not needed on this path: with no `plan` block there are no marketplace terms
  # to accept. Left false so a stray `true` cannot imply this is a billed
  # deployment.
  accept_marketplace_terms = false
}

data "http" "my_ip" {
  url = "https://api.ipify.org"
}
```

Below 8 vCores SAT's own sizing advisory returns "upsize" for training
workloads, and says so on screen. `Standard_D8s_v5` avoids that during a demo;
smaller sizes are fine for a topology-only check.

## Before it will apply at all

Four resource providers must be registered in the subscription: this list grew
from three to four on 2026-08-20 (hailbytes-sat#912) when Microsoft.Cache
turned out to be missing too — `enable_managed_redis` defaults to `true`, so a
default HA apply creates an Azure Cache for Redis whether or not an earlier
version of this doc mentioned it. Treat the list below, not this doc's git
history, as current; the canonical copy lives in
[`quickstart/preflight-azure.sh`](../quickstart/preflight-azure.sh)'s
`HA_ONLY_PROVIDERS` and is asserted against by
[`quickstart/tests/cloud_prereqs_test.sh`](../quickstart/tests/cloud_prereqs_test.sh).

As of 2026-08-23 this is still what stops every HA smoke run: four consecutive
dispatches (2026-08-19 through 2026-08-22, mixing D2s/D4s/D8s_v5) all died in
preflight, before `terraform init`, because the smoke's OIDC principal
deliberately does not hold subscription-scoped write, so it cannot self-heal. A
subscription **owner** runs this once:

```bash
for ns in Microsoft.Cache Microsoft.DBforPostgreSQL Microsoft.KeyVault Microsoft.OperationalInsights; do
  az provider register --namespace "$ns" --wait
done
```

Confirm before spending an apply on it:

```bash
for ns in Microsoft.Cache Microsoft.DBforPostgreSQL Microsoft.KeyVault Microsoft.OperationalInsights; do
  printf '%-34s %s\n' "$ns" "$(az provider show --namespace "$ns" --query registrationState -o tsv)"
done
```

All four must read `Registered`.

## Checking it actually works

A green apply means Terraform created resources. It does not mean the product is
serving. Two checks from `hailbytes-sat/scripts/ci/`:

```bash
LB_IP="$(terraform output -raw lb_public_ip)"

# Real login: /login is a CSRF-protected form POST. /api/login does not exist,
# and probing it returns 404 no matter what the password is.
bash scripts/ci/lb_login_probe.sh "https://${LB_IP}" admin "$ADMIN_PW"

# A session minted on one node must be readable on the other. Exits non-zero
# unless it can actually demonstrate more than one node served the requests.
bash scripts/ci/lb_session_hop.sh "https://${LB_IP}" admin "$ADMIN_PW" 40
```

Get `ADMIN_PW` from either node — on an HA pair both hold the same value once
the shared-secret path is in the image:

```bash
az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript \
  --scripts 'sudo cat /opt/hailbytes-sat/hailbytes-sat-initial-credentials.txt' \
  --query 'value[0].message' -o tsv
```

Destroy it when you are done. These are billable VMs and a Flexible Server.
