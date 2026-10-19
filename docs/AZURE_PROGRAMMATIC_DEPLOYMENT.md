# Programmatic deployment from Azure Marketplace

HailBytes SAT and ASM ship as paid Azure Marketplace VM images. Before any
script, pipeline or Terraform run can start a VM from one, the image's legal
terms must be accepted for the subscription. The portal calls that **enabling
programmatic deployment**. This page explains what it is, the three ways to do
it, and the decision that matters most: **who owns the acceptance**.

It applies to every Azure module and quickstart root in this repo, for both
products.

---

## The short version

1. Subscribe to the listing in the portal while signed in to the target
   subscription.
2. Accept the terms **once per subscription, per product**, outside Terraform:

   ```bash
   ./quickstart/preflight-azure.sh ha --product sat --accept-terms
   ```

3. In every deployment in that subscription, set:

   ```hcl
   accept_marketplace_terms = false
   ```

   The quickstart roots do this for you when `customer` is set.

That is the setup to use for anything beyond a single throwaway deployment. The
rest of this page is why, and what to do when you are not starting clean.

---

## What "programmatic deployment" actually is

When someone clicks **Create** on a Marketplace listing, the portal accepts the
offer's terms on their behalf as part of the purchase. A script never sees that
page, so Azure requires the same acceptance to be recorded ahead of time,
as an **agreement** on the subscription
(`Microsoft.MarketplaceOrdering/agreements`). Without it, the VM create is
refused, even though the image is visible and the caller has every other
permission.

Three facts shape everything else:

- **It is per subscription.** One acceptance covers every deployment in that
  subscription, whoever runs them.
- **It is per offer and plan.** SAT and ASM are separate offers, so an MSSP
  running both accepts twice.
- **It creates nothing and costs nothing on its own.** Billing starts when a VM
  runs the image.

The identifiers, for scripts and policy:

| Product | Publisher | Offer | Plan |
|---|---|---|---|
| SAT | `lcmcon1687976613543` | `gophish-phishing-simulator` | `standard-v2` |
| ASM | `lcmcon1687976613543` | `hardened_ubuntu_with_rengine` | `standard-v2` |

---

## Three ways to accept the terms

All three record the same agreement. Pick by who is doing it.

### 1. Azure portal: the "programmatic deployment" toggle

For a subscription owner who prefers clicking:

1. Open the listing ([SAT](https://marketplace.microsoft.com/en-us/product/virtual-machines/lcmcon1687976613543.gophish-phishing-simulator)
   or [ASM](https://marketplace.microsoft.com/en-us/product/virtual-machines/lcmcon1687976613543.hardened_ubuntu_with_rengine))
   while signed in to the portal, and choose **Get it now** / **Create**.
2. Below the plan selector, click **Want to deploy programmatically? Get
   started**.
3. On **Configure Programmatic Deployment**, set your subscription to
   **Enable**.
4. **Save.**

If the page says *You don't have permissions to configure programmatic
deployments using these subscriptions*, that is as far as you can go. Send the
request below to a subscription owner.

### 2. Azure CLI

For an admin with the rights, in Cloud Shell or any signed-in CLI:

```bash
# SAT
az vm image terms accept --publisher lcmcon1687976613543 \
  --offer gophish-phishing-simulator --plan standard-v2
# ASM
az vm image terms accept --publisher lcmcon1687976613543 \
  --offer hardened_ubuntu_with_rengine --plan standard-v2
```

Azure PowerShell does the same with
`Set-AzMarketplaceTerms -Publisher lcmcon1687976613543 -Product gophish-phishing-simulator -Name standard-v2 -Accept`.

### 3. The preflight script (recommended)

`quickstart/preflight-azure.sh` already checks everything else a first apply
needs: resource providers, the image in your region, zones and quota. With
`--accept-terms` it also accepts the terms as a deliberate, logged step. It is
off by default, because accepting legal terms on someone's subscription should
be a choice someone makes, not a side effect.

```bash
git clone --depth 1 https://github.com/HailBytes/hailbytes-terraform-modules
cd hailbytes-terraform-modules
./quickstart/preflight-azure.sh ha --product sat --location northeurope --accept-terms
```

Read the **Marketplace image terms** section of its output:

| It prints | Meaning |
|---|---|
| `terms already accepted` | Done. Nothing changed. |
| `accepting now (--accept-terms was passed)` then `accepted` | Done, just now. |
| `FAILED to accept terms. A subscription Owner may need to do this.` | Your identity lacks the right. Forward the request below. |
| `could not read terms state.` | Usually the subscription has not subscribed to the listing yet. Do step 1 of [The short version](#the-short-version). |
| `terms NOT accepted.` | You ran it without `--accept-terms`. |

### Who can accept

Accepting is a subscription-level write, so it needs **Owner or Contributor on
the subscription**. Contributor on a resource group is not enough. That is why
it often has to come from someone other than the person deploying. Two
organisation-wide settings can also block it:

- **Private Marketplace.** If your organisation runs one, the HailBytes offer
  must be on its approved list first.
- **Billing account policy.** Enterprise and Microsoft Customer Agreement
  billing accounts can disable paid Marketplace purchases.

A request to forward as-is:

> Please enable programmatic deployment for subscription *<name>* on the
> HailBytes SAT Marketplace offering (publisher `lcmcon1687976613543`, offer
> `gophish-phishing-simulator`, plan `standard-v2`). Portal path: Marketplace,
> the offering, **Want to deploy programmatically? Get started**, set the
> subscription to **Enable**, **Save**. Or from the CLI:
> `az vm image terms accept --publisher lcmcon1687976613543 --offer gophish-phishing-simulator --plan standard-v2`.
> It is a one-time setting and creates no resources by itself.

---

## The decision that matters: who owns the acceptance

The modules can also accept the terms themselves, through an
`azurerm_marketplace_agreement` resource controlled by
`accept_marketplace_terms`. That works, but it makes **one deployment's
Terraform state the owner of a subscription-wide setting**, and Terraform
treats what it owns as its own to delete. So pick one owner:

| | **A. Terraform owns it** | **B. Accepted once, outside Terraform** |
|---|---|---|
| How | `accept_marketplace_terms = true` (the module default, and the quickstart default when `customer` is unset) | Portal toggle, CLI or `preflight-azure.sh --accept-terms`, then `accept_marketplace_terms = false` everywhere |
| Second deployment in the same subscription | **Fails** with `already exists - to be managed via Terraform this resource needs to be imported` | Works |
| Destroying a deployment | **Cancels the terms for the whole subscription**, which breaks image swaps and scale-out for every other HailBytes deployment there | Leaves the terms alone |
| Pipeline identity needs subscription-level rights | Yes, on every apply that creates the agreement | No; only the one-time acceptance does |
| Right for | One throwaway deployment, alone in its subscription | Everything else: production, MSSPs, several deployments, CI/CD, central governance |

**Use B.** The quickstart roots already do this when you set `customer`
(`azure-single`, `azure-ha`, `azure-autoscale` and their ASM equivalents).
`azure-ha-byoip` has no `customer` input, so set `accept_marketplace_terms =
false` there yourself.

One combination fails every time and is worth calling out. If you accept the
terms first (any of the three ways) and **then** apply a root that still has
`accept_marketplace_terms = true`, the apply stops at the agreement with
`already exists`. Nothing is broken. Set the variable to `false` and apply
again. **Do not import the agreement** to make the error go away: importing
makes that deployment the owner, and destroying it later cancels the terms for
everyone.

### Moving an existing deployment from A to B

A deployment created with `accept_marketplace_terms = true` owns the agreement.
If you simply flip the variable to `false`, the next plan **destroys** the
agreement, which cancels the terms. Release it from state first:

```bash
terraform state list | grep azurerm_marketplace_agreement
terraform state rm '<the address it printed>'
# now set accept_marketplace_terms = false in terraform.tfvars
terraform plan    # must show no change to any marketplace agreement
```

The agreement stays accepted on the subscription; Terraform just stops claiming
it. Do the same before destroying an old deployment that shares its
subscription with others (see `docs/AZURE_MSSP_RUNBOOK.md`, Step 10).

---

## Deploying from a pipeline

Option B is what makes an unattended pipeline practical. The pipeline's service
principal or workload identity then needs only what the deployment itself
creates. It needs no right to accept terms or register providers.

1. **Once, by a subscription Owner:**
   `./quickstart/preflight-azure.sh <tier> --product <sat|asm> --location <region> --accept-terms`.
   This registers the resource providers and accepts the terms.
2. **In the pipeline**, with the root's `accept_marketplace_terms = false`
   (or `customer` set):

   ```bash
   # Authentication comes from the pipeline's environment, e.g. ARM_CLIENT_ID,
   # ARM_TENANT_ID, ARM_SUBSCRIPTION_ID and ARM_USE_OIDC=true.
   terraform init -input=false
   terraform plan -input=false -out=tfplan
   terraform apply -input=false tfplan
   ```

3. **Grant the deploying identity the Key Vault and role rights** the modules
   need: Owner, or Contributor plus User Access Administrator. The modules
   create role assignments, which Contributor alone cannot. Scope it to the
   subscription when you deploy a quickstart root, because every root creates
   its own resource group; a root of your own that takes an existing resource
   group can scope it to that group. `preflight-azure.sh` prints this in its
   last section.

Keep state in a remote backend (`quickstart/bootstrap-state-azure.sh`), so the
pipeline and people at a terminal see the same state.

---

## Verify before you apply

```bash
# Terms accepted? Expect: true
az vm image terms show --publisher lcmcon1687976613543 \
  --offer gophish-phishing-simulator --plan standard-v2 --query accepted -o tsv

# Image visible in the region you are deploying to? Expect one or more versions.
az vm image list --publisher lcmcon1687976613543 --offer gophish-phishing-simulator \
  --sku standard-v2 --all -l northeurope -o table
```

Accepted terms and a visible image are different things. Terms are per
subscription; image availability is per region. `preflight-azure.sh` checks
both.

---

## When it goes wrong

`quickstart/explain.sh apply.log` recognises the first two of these and prints
the fix.

| Error | Meaning | Fix |
|---|---|---|
| `MarketplacePurchaseEligibilityFailed`, `you must accept the terms`, `must agree to the legal terms` | No agreement on this subscription | Accept once (any of the three ways), or set `accept_marketplace_terms = true` for a lone deployment |
| `already exists - to be managed via Terraform this resource needs to be imported` on `azurerm_marketplace_agreement` | Terms already accepted, and this root also tries to own them | `accept_marketplace_terms = false`, apply again. Do not import |
| `You don't have permissions to configure programmatic deployments using these subscriptions` (portal) | You are not Owner or Contributor on the subscription | Forward the request above |
| `PurchaseNotAllowed` | A Private Marketplace or billing-account policy blocks the offer | Your Azure or billing administrator allows the offer |
| Image not found in the region, or preflight reports `NO image visible` | Not subscribed yet, or the region is not enabled for the offer | Subscribe from the listing; try a region where `az vm image list` shows a version |
| Image swaps or scale-out start failing after someone destroyed a deployment | That deployment owned the agreement, and destroying it cancelled the terms | Accept again (portal, CLI or preflight), then move every remaining deployment to option B |

---

## Not for customers: deploying from the HailBytes image gallery

`docs/DEPLOY_FROM_GALLERY.md` describes setting `source_image_id` to boot an
image straight from HailBytes' own compute gallery. That path has no
Marketplace plan, so there are no terms to accept, and also **no metering**. It
exists only for HailBytes' internal pre-release testing. A customer deployment
always uses the Marketplace image, and a non-null `source_image_id` outside
that testing is a defect.

---

## Related

- `docs/AZURE_MSSP_RUNBOOK.md`: Step 2 (subscription prep) and Step 10 (teardown that keeps the terms intact)
- `quickstart/preflight-azure.sh`: the checks and `--accept-terms`
- `quickstart/explain.sh`: turns an apply log into the next step
- hailbytes-sat `docs/ENTRA_ID_SSO.md`: signing in with Entra ID once SAT is running
