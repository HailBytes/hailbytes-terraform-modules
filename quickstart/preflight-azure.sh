#!/usr/bin/env bash
# HailBytes SAT — Azure subscription preflight.
#
# Run this ONCE per subscription, in Azure Cloud Shell, before the first
# terraform apply. It is idempotent: re-running it is harmless.
#
#   curl -fsSL https://raw.githubusercontent.com/hailbytes/hailbytes-terraform-modules/main/quickstart/preflight-azure.sh | bash -s -- ha
#
# Or, from a clone:
#
#   ./quickstart/preflight-azure.sh ha        # HA hot-hot tier (two VMs + Flexible Server)
#   ./quickstart/preflight-azure.sh single    # single-VM tier
#
# Add --location <region> (or set HB_LOCATION) to check the region you will
# actually deploy into. Three of the checks below are regional -- marketplace
# image availability, availability zones, and compute quota -- and getting a
# "no" on any of them during the deployment call is the expensive way to find
# out.
#
# WHY THIS EXISTS
# The Terraform modules set resource_provider_registrations = "none" on the
# azurerm provider on purpose. The provider's default sweeps ~70 providers on
# every apply, and registration is a SUBSCRIPTION-scoped write
# (*/register/action) that most delegated service principals and many
# least-privilege operator roles do not hold. With the sweep on, an apply fails
# closed with a wall of 403s before creating anything -- including for providers
# the stack never touches.
#
# Turning the sweep off makes the requirement explicit rather than implicit, and
# this script is the explicit step. Without it the first apply fails with
# "API version ... was not found for Microsoft.X", which points at the API
# version rather than at the cause.
#
# WHAT IT CHANGES
#   * Registers resource providers (subscription-scoped, one-time, additive).
#     Registering a provider does not create resources and is not billable.
#   * Accepts Azure Marketplace image terms for the HailBytes SAT offer, but
#     ONLY with --accept-terms. Left off by default because accepting legal
#     terms on someone's subscription should be a deliberate act.
# It creates no resource groups, networks, VMs or databases.

set -uo pipefail

TIER="${1:-ha}"
ACCEPT_TERMS=0
LOCATION="${HB_LOCATION:-northeurope}"

# Parse the flags after the tier. --location takes a value, so a plain
# `for arg in "$@"` cannot read it.
shift $(( $# > 0 ? 1 : 0 ))
while [ $# -gt 0 ]; do
    case "$1" in
        --accept-terms) ACCEPT_TERMS=1 ;;
        --location)
            [ $# -ge 2 ] || { echo "--location needs a region, e.g. --location northeurope" >&2; exit 2; }
            LOCATION="$2"
            shift
            ;;
        --location=*) LOCATION="${1#--location=}" ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

case "$TIER" in
    ha|single) ;;
    *)
        echo "usage: $0 {ha|single} [--accept-terms]" >&2
        exit 2
        ;;
esac

# Marketplace plan for the SAT offer. Keep in sync with
# modules/ha-hot-hot/azure/main.tf local.marketplace_plans.
PUBLISHER="lcmcon1687976613543"
OFFER="gophish-phishing-simulator"
SKU="standard-v2"

# The module default application-node size, and its vCPU count. Keep in sync
# with the vm_size defaults in modules/*/azure/variables.tf -- the quota check
# below is only useful if it asks about the size Terraform will actually ask
# for.
VM_SKU="Standard_D8s_v5"
VM_SKU_VCPUS=8

# Providers each tier genuinely creates resources under.
#
# The HA tier adds DBforPostgreSQL (Flexible Server), KeyVault (the shared DB
# password and session keys) and Cache (Azure Cache for Redis) on top of the
# single-VM set.
#
# Microsoft.Cache is NOT optional by default: enable_managed_redis defaults to
# TRUE and redis_endpoint_override defaults to null, so provision_managed_redis
# is true and azurerm_redis_cache is created on a default HA apply. Set
# enable_managed_redis = false (Redis is a performance optimisation, not an HA
# requirement) if you want to skip it -- but the default needs the namespace.
#
# Application Gateway lives under Microsoft.Network, so enabling it adds no
# namespace here.
COMMON_PROVIDERS=(
    Microsoft.Compute
    Microsoft.Network
    Microsoft.Storage
    Microsoft.ManagedIdentity
    Microsoft.MarketplaceOrdering
    Microsoft.Insights
    Microsoft.OperationalInsights
    Microsoft.KeyVault
)
HA_ONLY_PROVIDERS=(
    Microsoft.DBforPostgreSQL
    Microsoft.Cache
)

if [ "$TIER" = "ha" ]; then
    PROVIDERS=("${COMMON_PROVIDERS[@]}" "${HA_ONLY_PROVIDERS[@]}")
else
    PROVIDERS=("${COMMON_PROVIDERS[@]}")
fi

echo "=============================================================="
echo " HailBytes SAT — Azure preflight (${TIER} tier)"
echo "=============================================================="
echo

# ---------- 1. Who are we, and where ----------
if ! SUB_JSON="$(az account show -o json 2>/dev/null)"; then
    echo "ERROR: not logged in to Azure CLI. In Cloud Shell this should already" >&2
    echo "       be done; otherwise run 'az login' first." >&2
    exit 1
fi
SUB_NAME="$(printf '%s' "$SUB_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
SUB_ID="$(printf '%s' "$SUB_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
USER_NAME="$(printf '%s' "$SUB_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("user",{}).get("name","(unknown)"))')"

echo "Subscription : ${SUB_NAME}"
echo "  id         : ${SUB_ID}"
echo "  signed in  : ${USER_NAME}"
echo
echo "If that is not the subscription you intend to deploy into, stop now and run:"
echo "  az account set --subscription '<name-or-id>'"
echo

# ---------- 2. Resource providers ----------
echo "--------------------------------------------------------------"
echo " Resource providers"
echo "--------------------------------------------------------------"

to_register=()
unreadable=()

for ns in "${PROVIDERS[@]}"; do
    state="$(az provider show --namespace "$ns" --query registrationState -o tsv 2>/dev/null || true)"
    if [ -z "$state" ]; then
        printf '  %-34s %s\n' "$ns" "unreadable"
        unreadable+=("$ns")
        continue
    fi
    printf '  %-34s %s\n' "$ns" "$state"
    [ "$state" = "Registered" ] || to_register+=("$ns")
done
echo

if [ ${#unreadable[@]} -gt 0 ]; then
    echo "WARNING: could not read registration state for: ${unreadable[*]}"
    echo "         Reading it is itself a subscription-scoped read, so a narrow"
    echo "         role may lack it. Continuing; if apply later fails with"
    echo "         'API version ... was not found for Microsoft.X', X is the"
    echo "         unregistered one."
    echo
fi

if [ ${#to_register[@]} -eq 0 ]; then
    echo "All required providers are already registered. Nothing to do."
else
    echo "Registering ${#to_register[@]} provider(s). This is a one-time,"
    echo "subscription-scoped, non-billable change and can take a few minutes."
    echo
    failed=()
    for ns in "${to_register[@]}"; do
        printf '  registering %-30s ' "$ns"
        if az provider register --namespace "$ns" --wait >/dev/null 2>&1; then
            echo "done"
        else
            echo "FAILED"
            failed+=("$ns")
        fi
    done
    echo
    if [ ${#failed[@]} -gt 0 ]; then
        echo "ERROR: could not register: ${failed[*]}" >&2
        echo "" >&2
        echo "This is almost always a permissions problem, not a typo." >&2
        echo "Registering a provider needs */register/action at SUBSCRIPTION" >&2
        echo "scope, which Contributor on a resource group does not include." >&2
        echo "Ask someone with Owner or Contributor at subscription scope to run:" >&2
        echo "" >&2
        for ns in "${failed[@]}"; do
            echo "  az provider register --namespace ${ns} --wait" >&2
        done
        exit 1
    fi
fi
echo

# ---------- 3. Marketplace image terms ----------
echo "--------------------------------------------------------------"
echo " Marketplace image terms"
echo "--------------------------------------------------------------"
echo "Offer: ${PUBLISHER}:${OFFER}:${SKU}"

terms_state="$(az vm image terms show --publisher "$PUBLISHER" --offer "$OFFER" --plan "$SKU" \
                 --query accepted -o tsv 2>/dev/null || true)"

if [ "$terms_state" = "true" ]; then
    echo "  terms already accepted"
elif [ -z "$terms_state" ]; then
    echo "  could not read terms state."
    echo "  Most often this means the subscription has no entitlement to the"
    echo "  offer yet. Subscribe to the listing first:"
    echo "    https://marketplace.microsoft.com/en-us/product/virtual-machines/${PUBLISHER}.${OFFER}"
elif [ "$ACCEPT_TERMS" = "1" ]; then
    echo "  terms not accepted; accepting now (--accept-terms was passed)"
    if az vm image terms accept --publisher "$PUBLISHER" --offer "$OFFER" --plan "$SKU" >/dev/null 2>&1; then
        echo "  accepted"
    else
        echo "  FAILED to accept terms. A subscription Owner may need to do this." >&2
    fi
else
    echo "  terms NOT accepted."
    echo "  The Terraform module can accept them during apply"
    echo "  (accept_marketplace_terms), or re-run this script with"
    echo "  --accept-terms to do it now as an explicit, auditable step."
fi
echo

# ---------- 4. Marketplace image availability in the target region ----------
#
# Accepted terms and an available image are different things. Terms are
# subscription-scoped; availability is regional, and an offer enabled for one
# region is not thereby enabled for another. Getting this wrong surfaces as a
# terraform apply that fails on the VM -- after the vnet, the Key Vault and the
# database already exist.
echo "--------------------------------------------------------------"
echo " Marketplace image in ${LOCATION}"
echo "--------------------------------------------------------------"

active="$(az vm image list --publisher "$PUBLISHER" --offer "$OFFER" --sku "$SKU" \
            --all -l "$LOCATION" \
            --query "[?imageDeprecationStatus.imageState=='Active'].version" -o tsv 2>/dev/null || true)"
deprecating="$(az vm image list --publisher "$PUBLISHER" --offer "$OFFER" --sku "$SKU" \
            --all -l "$LOCATION" \
            --query "[?imageDeprecationStatus.imageState!='Active'].[version,imageDeprecationStatus.scheduledDeprecationTime]" \
            -o tsv 2>/dev/null || true)"

if [ -z "$active" ] && [ -z "$deprecating" ]; then
    echo "  NO image visible for ${PUBLISHER}:${OFFER}:${SKU} in ${LOCATION}."
    echo
    echo "  Most likely one of:"
    echo "    * the subscription has not subscribed to the offer yet, or"
    echo "    * the offer is not enabled for ${LOCATION} in Partner Center, or"
    echo "    * ${LOCATION} is not a valid region name."
    echo
    echo "  Subscribe: https://marketplace.microsoft.com/en-us/product/virtual-machines/${PUBLISHER}.${OFFER}"
    echo "  A deployment into this region fails at the VM until this reads Active."
elif [ -z "$active" ]; then
    echo "  Images are visible but NONE is Active -- every published version"
    echo "  carries a deprecation date. Check Partner Center before deploying."
else
    echo "  Active version(s): $(printf '%s' "$active" | tr '\n' ' ')"
    echo "  marketplace_image_version defaults to \"latest\", which resolves to"
    echo "  this. Pin it explicitly for a reproducible deployment."
fi

if [ -n "$deprecating" ]; then
    echo
    echo "  Scheduled for deprecation -- do not pin these:"
    printf '%s\n' "$deprecating" | awk -F'\t' '{printf "    %-14s deprecates %s\n", $1, $2}'
fi
echo

# ---------- 5. Availability zones ----------
#
# The HA tier pins its two VMs to zones 1 and 2 (ha-hot-hot/azure vm_zones) and
# runs a ZoneRedundant Flexible Server. Neither is optional, and not every
# Azure region has zones -- in one that does not, apply fails on the first VM.
if [ "$TIER" = "ha" ]; then
    echo "--------------------------------------------------------------"
    echo " Availability zones in ${LOCATION}"
    echo "--------------------------------------------------------------"
    zones="$(az vm list-skus -l "$LOCATION" --resource-type virtualMachines \
               --query "[?name=='${VM_SKU}'].locationInfo[0].zones | [0]" -o tsv 2>/dev/null || true)"
    if [ -z "$zones" ]; then
        echo "  Could not read zone support for ${VM_SKU} in ${LOCATION}."
        echo "  Either the SKU is not offered there, the region name is wrong, or"
        echo "  the identity lacks subscription read. The HA tier REQUIRES zones 1"
        echo "  and 2; verify before deploying:"
        echo "    az vm list-skus -l ${LOCATION} --resource-type virtualMachines --query \"[?name=='${VM_SKU}']\" -o json"
    else
        echo "  ${VM_SKU} is offered in zones: $(printf '%s' "$zones" | tr '\n\t' '  ')"
        for z in 1 2; do
            if ! printf '%s' "$zones" | grep -qw "$z"; then
                echo "  WARNING: zone ${z} is not available for ${VM_SKU} here."
                echo "  The HA tier pins zones 1 and 2 and will fail to apply."
            fi
        done
    fi
    echo
fi

# ---------- 6. Compute quota ----------
echo "--------------------------------------------------------------"
echo " Compute quota in ${LOCATION}"
echo "--------------------------------------------------------------"
if [ "$TIER" = "ha" ]; then
    node_count=2
else
    node_count=1
fi
needed=$(( node_count * VM_SKU_VCPUS ))

echo "The ${TIER} tier builds ${node_count} application VM(s) at ${VM_SKU}"
echo "(${VM_SKU_VCPUS} vCPUs each) by default, so it needs ${needed} vCPUs of"
echo "'Standard DSv5 Family' quota here."
if [ "$TIER" = "ha" ]; then
    echo "The Flexible Server and the Redis cache draw their own quotas, separate"
    echo "from this one."
fi
echo

usage_line="$(az vm list-usage --location "$LOCATION" -o tsv 2>/dev/null \
                | grep -i 'standardDSv5Family' || true)"
if [ -z "$usage_line" ]; then
    echo "  Could not read quota for ${LOCATION} (needs subscription read)."
    echo "  Check it by hand:"
    echo "    az vm list-usage --location ${LOCATION} -o table | grep -i DSv5"
else
    current="$(printf '%s' "$usage_line" | awk '{print $(NF-1)}')"
    limit="$(printf '%s' "$usage_line" | awk '{print $NF}')"
    if [ -n "$limit" ] && [ "$limit" -eq "$limit" ] 2>/dev/null; then
        available=$(( limit - current ))
        echo "  Standard DSv5 Family: ${current} used of ${limit} — ${available} available."
        if [ "$available" -lt "$needed" ]; then
            echo
            echo "  NOT ENOUGH. This deployment needs ${needed} and can get ${available}."
            echo "  Request an increase in the portal (Subscription > Usage + quotas)"
            echo "  before the deployment call -- approval is not instant."
        else
            echo "  Sufficient for the default sizing."
        fi
    else
        echo "  ${usage_line}"
    fi
fi
echo
echo "Smaller SKUs are supported. Since 2026-08-26 the product's sizing advisory"
echo "escalates on MEASURED load rather than on core count, so a deliberately"
echo "small instance is not told to upsize while it has headroom -- see"
echo "hailbytes-sat/docs/VM_SCALING.md. Which sizes you can BUY is a separate"
echo "question, set by the SKUs published on the marketplace listing."
echo

# ---------- 7. RBAC the deploying principal needs ----------
echo "--------------------------------------------------------------"
echo " Permissions the deploying identity needs"
echo "--------------------------------------------------------------"
echo "Beyond creating resources, the modules assign roles: each VM's managed"
echo "identity is granted 'Key Vault Secrets User' so it can read the database"
echo "password, and the deployer is granted 'Key Vault Secrets Officer' to"
echo "write it."
echo
echo "Creating role assignments needs Microsoft.Authorization/roleAssignments/write,"
echo "which Contributor does NOT include. The deploying identity therefore needs"
echo "Owner, or Contributor plus User Access Administrator, on the target"
echo "resource group or subscription."
echo
echo "This is the second most common first-apply failure after unregistered"
echo "providers, and it surfaces late -- after VMs already exist."
echo

echo "=============================================================="
echo " Preflight complete for the ${TIER} tier in ${LOCATION}."
echo "=============================================================="
