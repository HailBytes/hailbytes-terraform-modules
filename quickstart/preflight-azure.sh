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
for arg in "$@"; do
    [ "$arg" = "--accept-terms" ] && ACCEPT_TERMS=1
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

# ---------- 4. Compute quota ----------
echo "--------------------------------------------------------------"
echo " Compute quota (informational)"
echo "--------------------------------------------------------------"
if [ "$TIER" = "ha" ]; then
    echo "The HA tier builds TWO application VMs plus a Flexible Server and an"
    echo "Azure Cache for Redis. The default VM SKU is"
    echo "Standard_D8s_v5 (8 vCPUs each), so it needs 16 vCPUs of"
    echo "'Standard DSv5 Family' quota in your chosen region, plus headroom"
    echo "for the Flexible Server."
else
    echo "The single-VM tier builds ONE application VM. The default SKU is"
    echo "Standard_D8s_v5 (8 vCPUs), so it needs 8 vCPUs of"
    echo "'Standard DSv5 Family' quota in your chosen region."
fi
echo
echo "Check the region you plan to deploy into, e.g.:"
echo "  az vm list-usage --location northeurope -o table | grep -i 'DSv5'"
echo
echo "Below 8 vCPUs the product's own sizing advisory reports 'upsize' for"
echo "training workloads and says so on screen, so smaller SKUs are suitable"
echo "for phishing simulation only."
echo

# ---------- 5. RBAC the deploying principal needs ----------
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
echo " Preflight complete for the ${TIER} tier."
echo "=============================================================="
