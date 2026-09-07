#!/usr/bin/env bash
# HailBytes — turn a failed deployment into the next thing to DO.
#
#   ./quickstart/explain.sh <logfile>     explain a failed run
#   terraform apply 2>&1 | tee tf.log ; ./quickstart/explain.sh tf.log
#
# WHY THIS EXISTS
# A failed apply prints what the cloud said, which is often not what to do
# about it — and sometimes not even what went wrong. Two real examples from
# customer deployments:
#
#   * "SoftDeletedVaultDoesNotExist" on a Key Vault. Nothing to do with soft
#     delete. The provider's pre-create lookup is a subscription-scoped read
#     that an operator with resource-group-scoped access cannot perform.
#   * "Multi-Zone HA is not supported in this region" on Postgres. The region
#     supports it fine; that subscription is not entitled to it. Changing
#     region does not help.
#
# Each of those cost a round trip with a customer to work out. A round trip
# costs a day, and most people who hit a wall never open one — they just stop.
# So every failure this project has seen is matched here, and each prints WHO
# can fix it, the exact command or portal page, and — where it needs someone
# with more access — a paragraph to forward as-is.
#
# It is read-only: no cloud credentials, no API calls, nothing changed. That
# also makes it safe to run against a log somebody emails you.

set -uo pipefail

C_YLW=$'\033[33m'; C_CYN=$'\033[36m'; C_GRN=$'\033[32m'
C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
# Colour off when piped. This output gets pasted into email and ticket
# systems, where escape codes are noise that hides the instructions.
[ -t 1 ] || { C_YLW=""; C_CYN=""; C_GRN=""; C_BLD=""; C_OFF=""; }

LOG="${1:-}"
if [ -z "$LOG" ] || [ "$LOG" = "-h" ] || [ "$LOG" = "--help" ]; then
    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    [ -z "$LOG" ] && exit 2 || exit 0
fi
[ -r "$LOG" ] || { echo "cannot read: $LOG" >&2; exit 2; }

FOUND=0
hit()  { FOUND=$((FOUND+1)); printf '\n%s%s== %s ==%s\n' "$C_CYN" "$C_BLD" "$1" "$C_OFF"; }
does() { printf '%sWHAT HAPPENED%s   %s\n' "$C_BLD" "$C_OFF" "$*"; }
who()  { printf '%sWHO CAN FIX IT%s  %s\n' "$C_BLD" "$C_OFF" "$*"; }
do_()  { printf '%sDO THIS%s         %s\n' "$C_BLD" "$C_OFF" "$*"; }
cont() { printf '                %s\n' "$*"; }
cmd()  { printf '                %s%s%s\n' "$C_GRN" "$*" "$C_OFF"; }
fwd()  { printf '  | %s\n' "$*"; }
has()  { grep -qiF -- "$1" "$LOG"; }

# Which cloud is this? Only used to avoid offering AWS advice on an Azure
# failure and vice versa.
CLOUD="unknown"
has "azurerm" || has "Microsoft." || has "az " && CLOUD="azure"
has "aws_" || has "arn:aws" && CLOUD="aws"

# ===========================================================================
# Permissions. First, because it is the single largest category, and because
# the cloud's own message contains everything needed to make the request.
# ===========================================================================
if has "does not have authorization to perform action" || has "AuthorizationFailed" \
   || has "UnauthorizedOperation" || has "is not authorized to perform"; then
    hit "Permissions: an action was refused"
    does "The cloud refused a specific action at a specific scope. Both are in"
    cont "the message, so this does not need guessing — and the block below is"
    cont "a complete request, not a starting point for a conversation."
    printf '\n'

    # Azure: ...perform action 'X' over scope 'Y'...
    ACTIONS="$(grep -oiE "perform action '[^']+'" "$LOG" | sed "s/.*'\(.*\)'/\1/" | sort -u)"
    SCOPES="$(grep -oiE "over scope '[^']+'" "$LOG" | sed "s/.*'\(.*\)'/\1/" | sort -u)"
    # AWS: ...is not authorized to perform: ec2:RunInstances on resource: ...
    [ -z "${ACTIONS//[[:space:]]/}" ] && \
        ACTIONS="$(grep -oiE "not authorized to perform:? ?[a-z0-9-]+:[A-Za-z]+" "$LOG" \
                    | grep -oiE "[a-z0-9-]+:[A-Za-z]+$" | sort -u)"
    [ -z "${SCOPES//[[:space:]]/}" ] && \
        SCOPES="$(grep -oiE "on resource:? ?arn:aws:[^ \"']+" "$LOG" \
                    | grep -oiE "arn:aws:[^ \"']+" | sort -u)"

    if [ -n "${ACTIONS//[[:space:]]/}" ]; then
        printf '%sREFUSED ACTIONS%s\n' "$C_BLD" "$C_OFF"
        printf '%s\n' "$ACTIONS" | sed 's/^/                /'
    fi
    if [ -n "${SCOPES//[[:space:]]/}" ]; then
        printf '%sAT SCOPE%s\n' "$C_BLD" "$C_OFF"
        printf '%s\n' "$SCOPES" | sed 's/^/                /'
    fi
    printf '\n'
    who "Whoever administers this subscription or account. Often not you."
    do_ "Forward everything between the bars:"
    printf '\n'
    fwd "Hello,"
    fwd ""
    fwd "A deployment I am running was refused. It needs permission for the"
    fwd "following action(s):"
    [ -n "${ACTIONS//[[:space:]]/}" ] && printf '%s\n' "$ACTIONS" | sed 's/^/  |     /'
    fwd ""
    fwd "at this scope (or anything above it):"
    [ -n "${SCOPES//[[:space:]]/}" ] && printf '%s\n' "$SCOPES" | sed 's/^/  |     /'
    fwd ""
    if [ "$CLOUD" = "azure" ]; then
        fwd "Two things that commonly cause confusion here:"
        fwd ""
        fwd "1. Owner granted on a RESOURCE or RESOURCE GROUP is not the same"
        fwd "   as Owner on the SUBSCRIPTION. Several actions this deployment"
        fwd "   performs are subscription-scoped and fail with resource-scoped"
        fwd "   Owner, even though the portal shows the role as Owner."
        fwd ""
        fwd "2. If the grant is time-boxed through PIM, it has to stay ACTIVE"
        fwd "   for the whole run, which takes roughly twenty minutes."
    fi
    fwd ""
    fwd "Thank you."
    printf '\n'
    if has "roleAssignments/write"; then
        cont "This one is role-assignment creation. The deployment grants each VM"
        cont "read access to its own secrets, which is itself a role assignment,"
        cont "so it needs USER ACCESS ADMINISTRATOR or Owner at the scope above."
        cont "Contributor can never do it, however broadly it is scoped."
    fi
    if has "CreateServiceLinkedRole"; then
        cont "This one is a service-linked role. It is a one-time, per-account,"
        cont "non-billable action that AWS itself performs — it does not grant"
        cont "anyone standing access:"
        cmd "./quickstart/preflight-aws.sh ha        # names the missing ones"
    fi
fi

# ===========================================================================
# Azure Key Vault: the error that names the wrong thing
# ===========================================================================
if has "SoftDeletedVaultDoesNotExist"; then
    hit "Key Vault: SoftDeletedVaultDoesNotExist"
    does "This names soft delete and is usually not about soft delete."
    cont "Before creating a vault the provider checks whether a soft-deleted"
    cont "one already holds the name. That check is a SUBSCRIPTION-scoped read:"
    cont "    Microsoft.KeyVault/locations/<region>/deletedVaults/<name>/read"
    cont "Access scoped to a resource group cannot perform it, and the provider"
    cont "then asks Azure to RECOVER a vault that never existed."
    printf '\n'
    who "You, in one line. No admin needed."
    do_ "Add this to the azurerm provider block in your root configuration:"
    cmd 'provider "azurerm" {'
    cmd '  features {'
    cmd '    key_vault {'
    cmd '      recover_soft_deleted_key_vaults = false'
    cmd '    }'
    cmd '  }'
    cmd '}'
    cont "The quickstart configurations in this repository already set it."
    printf '\n'
    cont "If it is already set and this still happens, a soft-deleted vault"
    cont "really does hold the name. Check, then choose another:"
    cmd "az keyvault list-deleted --query \"[].name\" -o tsv"
fi

# ===========================================================================
# Marketplace: terms / programmatic deployment / subscription
# ===========================================================================
if has "MarketplacePurchaseEligibilityFailed" || has "you must accept the terms" \
   || has "PurchaseNotAllowed" || has "must agree to the legal terms" \
   || has "OptInRequired" || has "not subscribed to this product"; then
    hit "Marketplace: the image is not enabled for programmatic deployment"
    does "These modules deploy a paid Marketplace image. Neither cloud will let"
    cont "a script deploy one until the offer has been accepted for the"
    cont "subscription or account. It is a one-time setting."
    printf '\n'
    who "Anyone who can accept Marketplace terms. Frequently not the deployer."
    if [ "$CLOUD" = "aws" ]; then
        do_ "Subscribe to the listing, then re-run:"
        cmd "SAT: https://aws.amazon.com/marketplace/pp/prodview-yyk6iton3ghu4"
        cmd "ASM: https://aws.amazon.com/marketplace/pp/prodview-66d5bswmbtfhs"
        cont "Accepting terms creates nothing and starts no charges on its own."
    else
        do_ "In the Azure portal, once per subscription:"
        cont "  1. Find the HailBytes offering in Marketplace."
        cont "  2. Under Create, click"
        cont "     'Want to deploy programmatically? Get started'."
        cont "  3. Set your subscription to Enable."
        cont "  4. Save."
        printf '\n'
        cont "If that page says 'You don't have permissions to configure"
        cont "programmatic deployments using these subscriptions', it is as far"
        cont "as you can go yourself — forward the block below."
        printf '\n'
        do_ "Or from the CLI, if you hold the rights:"
        cmd "az vm image terms accept --publisher lcmcon1687976613543 \\"
        cmd "  --offer gophish-phishing-simulator --plan standard-v2"
        printf '\n'
        fwd "Hello,"
        fwd ""
        fwd "Please enable programmatic deployment for our subscription on the"
        fwd "HailBytes Marketplace offering. Portal path: Marketplace -> the"
        fwd "offering -> 'Want to deploy programmatically? Get started' -> set"
        fwd "our subscription to Enable -> Save."
        fwd ""
        fwd "It is a one-time setting and creates no resources by itself."
        fwd ""
        fwd "Thank you."
    fi
fi

# ===========================================================================
# Compute quota
# ===========================================================================
if has "exceeding approved" || has "QuotaExceeded" || has "OperationNotAllowed" \
   || has "VcpuLimitExceeded" || has "InstanceLimitExceeded"; then
    hit "Compute quota"
    FAM="$(grep -oiE "approved [A-Za-z0-9]+ Cores quota" "$LOG" | awk '{print $2}' | sort -u | head -1)"
    LIM="$(grep -oiE "Current Limit: [0-9]+" "$LOG" | grep -oE '[0-9]+' | head -1)"
    does "This subscription or account has no room for the instance size"
    cont "requested${FAM:+ (family ${FAM})}."
    [ "${LIM:-x}" = "0" ] && \
        cont "Current Limit is 0 — the quota was never granted here at all, so it is not something that frees up on its own."
    printf '\n'
    who "You, by picking a family with room — or an admin, for an increase."
    if [ "$CLOUD" = "aws" ]; then
        do_ "Check what this account can run, then lower the instance type or"
        cont "request an increase in Service Quotas:"
        cmd "aws service-quotas list-service-quotas --service-code ec2 \\"
        cmd "  --query \"Quotas[?contains(QuotaName,'On-Demand')].[QuotaName,Value]\" --output text"
    else
        do_ "See what this subscription can actually run today:"
        cmd "az vm list-usage --location <region> \\"
        cmd "  --query \"[?contains(name.value,'Family')].[name.value,currentValue,limit]\" \\"
        cmd "  -o tsv | awk -F'\\t' '\$3+0>0'"
        cont "Then set vm_size to a size in a family that has room."
        printf '\n'
        cont "Note that every Dsv5 size — D2s_v5 through D64s_v5 — draws ONE"
        cont "pool, standardDSv5Family. If that pool is 0, no Dsv5 size works,"
        cont "whatever its vCPU count. Azure commonly grants it 0 in a"
        cont "subscription that has never asked for it, which is why the module"
        cont "default is a B-series size."
    fi
fi

# ===========================================================================
# Leftovers from an earlier attempt
# ===========================================================================
if has "needs to be imported into the State" || has "already exists"; then
    hit "A resource already exists from an earlier attempt"
    does "An earlier run created this and did not finish, so Terraform has no"
    cont "record of it — and the cloud will not create it twice. This is"
    cont "leftover debris, not a permissions problem."
    printf '\n'
    who "You. Nothing here needs an admin."
    if [ "$CLOUD" = "azure" ]; then
        do_ "See what is left, including the child resources that"
        cont "'az resource list' does not show:"
        cmd "./quickstart/sweep-azure.sh list --prefix <your-prefix>"
        cmd "./quickstart/sweep-azure.sh show <resource-group>"
        printf '\n'
        do_ "For leftovers from a failed attempt, deleting is almost always"
        cont "right — importing adopts a half-built resource nobody inspected:"
        cmd "./quickstart/sweep-azure.sh delete <resource-group>"
        printf '\n'
        cont "Deploying into a NEW resource group name also works and is"
        cont "quicker, but the old resources KEEP BILLING until somebody"
        cont "removes them, and each attempt leaves another group behind."
    else
        do_ "Either import the resource, or remove it and re-run. For debris"
        cont "from a failed attempt, removing is usually right."
    fi
fi

# ===========================================================================
# Azure Postgres: zone-redundant HA entitlement
# ===========================================================================
if has "MultiAzHaIsOfferRestricted"; then
    hit "Database: zone-redundant HA is not enabled on this subscription"
    does "The message says 'not supported in this region'. That is misleading:"
    cont "the region does support it, this SUBSCRIPTION is not entitled to it."
    cont "Changing region will not help, and no plan can see it in advance."
    printf '\n'
    who "You, by turning it off — or an admin, by requesting the entitlement."
    do_ "To get a working deployment now:"
    cmd 'db_high_availability_mode = "Disabled"'
    cont "The application VMs stay hot-hot across zones either way. What this"
    cont "gives up is the DATABASE standby: losing a zone becomes a restore"
    cont "rather than an automatic failover."
    printf '\n'
    do_ "To keep database HA instead, forward this:"
    printf '\n'
    fwd "Hello,"
    fwd ""
    fwd "Please raise an Azure support request to enable zone-redundant high"
    fwd "availability for Azure Database for PostgreSQL Flexible Server on"
    fwd "our subscription."
    fwd ""
    fwd "Azure returns MultiAzHaIsOfferRestricted with the message \"Multi-Zone"
    fwd "HA is not supported in this region\". That message is misleading — the"
    fwd "region supports it, our subscription is not entitled. It is a"
    fwd "per-subscription offer entitlement, so changing region will not help."
    fwd ""
    fwd "Thank you."
fi

# ===========================================================================
# Resource provider registration (Azure)
# ===========================================================================
if has "MissingSubscriptionRegistration" || has "was not found for Microsoft." \
   || has "SubscriptionNotRegistered"; then
    hit "A resource provider is not registered on this subscription"
    NS="$(grep -oiE "Microsoft\.[A-Za-z]+" "$LOG" | sort -u | tr '\n' ' ')"
    does "Registration is one-time, subscription-scoped and non-billable. The"
    cont "modules deliberately do not register providers themselves: the"
    cont "provider's default sweeps ~70 namespaces on every apply, which fails"
    cont "closed with a wall of 403s for most least-privilege roles."
    [ -n "${NS// /}" ] && cont "Namespaces mentioned in this log: ${NS% }"
    printf '\n'
    who "Anyone with */register/action on the subscription. Often not you."
    do_ "If you hold the rights, this names and fixes the missing ones:"
    cmd "./quickstart/preflight-azure.sh ha"
    printf '\n'
    fwd "Hello,"
    fwd ""
    fwd "Please register these resource providers on our subscription:"
    fwd "Microsoft.Compute, Microsoft.Network, Microsoft.KeyVault,"
    fwd "Microsoft.DBforPostgreSQL, Microsoft.OperationalInsights,"
    fwd "Microsoft.Storage, Microsoft.Cache."
    fwd ""
    fwd "Registration creates no resources and is not billable:"
    fwd "az provider register --namespace <name>"
    fwd ""
    fwd "Thank you."
fi

# ===========================================================================
# Globally-unique names
# ===========================================================================
if has "AccountNameInvalid" || has "StorageAccountAlreadyTaken" \
   || has "is already in use" || has "NameNotAvailable" \
   || has "BucketAlreadyExists"; then
    hit "A globally-unique name is taken"
    does "Storage account, Key Vault, database server and S3 bucket names are"
    cont "unique across the whole cloud, not just your account. Something has"
    cont "this one already — most often your own earlier attempt."
    printf '\n'
    who "You. Change the name prefix and re-run."
    do_ "Set a different name_prefix, then re-run the pre-flight, which tests"
    cont "each generated name for availability before anything is built:"
    if [ "$CLOUD" = "aws" ]; then cmd "./quickstart/preflight-aws.sh ha"
    else cmd "./quickstart/preflight-azure.sh ha"; fi
fi

# ===========================================================================
# Key Vault service endpoint / VNet conflicts (module-version issues)
# ===========================================================================
if has "SubnetsHaveNoServiceEndpointsConfigured" \
   || has "ConflictingPublicNetworkAccessAndVirtualNetworkConfiguration"; then
    hit "A module-version issue"
    does "Both of these were fixed in the modules in September 2026. Seeing"
    cont "one means the version in use predates the fix."
    printf '\n'
    who "You, by updating the module reference."
    do_ "Check the version or ref you are pinned to:"
    cmd "grep -rn 'source\\|ref=' *.tf | grep hailbytes"
    cont "Then move to the current release and re-run. Do not work around"
    cont "these by hand — the fixes are in the module for a reason."
fi

# ===========================================================================
printf '\n'
if [ "$FOUND" -eq 0 ]; then
    printf '%sNo known failure signature in %s%s\n' "$C_YLW" "$LOG" "$C_OFF"
    printf 'The lines below mention an error. If you are stuck, these plus the\n'
    printf 'log file are what to send — an unrecognised failure is worth adding\n'
    printf 'to this tool, so please do open an issue with them.\n\n'
    grep -nE '^Error:|Status: "|error:|failed' "$LOG" 2>/dev/null | head -12 | sed 's/^/  /'
else
    printf '%s%d known issue(s) explained.%s\n' "$C_BLD" "$FOUND" "$C_OFF"
    printf 'Each is either a change you can make yourself or a block to forward.\n'
    printf 'If you forward one, no further detail is needed.\n'
fi
printf '\n'
