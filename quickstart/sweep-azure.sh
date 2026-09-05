#!/usr/bin/env bash
# HailBytes — Azure deployment-leftover sweep.
#
# Repeated test deploys leave resource groups behind, and the leftovers are not
# inert. A half-built load balancer, an orphaned diagnostic setting or a
# pre-existing key vault makes the NEXT apply stop partway through with
#
#   Error: A resource with the ID "..." already exists - to be managed via
#   Terraform this resource needs to be imported into the State.
#
# which surfaces after other resources have been created, so the failed apply
# leaves its own debris behind. This script finds that debris and, when you ask
# it to by name, removes it.
#
#   ./quickstart/sweep-azure.sh list                  inventory matching groups
#   ./quickstart/sweep-azure.sh show <rg>             what is in one group
#   ./quickstart/sweep-azure.sh imports <rg>          PRINT terraform import commands
#   ./quickstart/sweep-azure.sh delete <rg>           delete one group, with guards
#
# Options (or the matching environment variable):
#   --prefix NAME       HB_NAME_PREFIX      only groups whose name contains NAME
#   --all                                   every group in the subscription
#   --subscription ID   HB_SUBSCRIPTION_ID  default: the current az context
#   --hostname HOST     HB_PUBLIC_HOSTNAME  a live hostname to protect (see below)
#   --module ADDR       HB_MODULE_ADDR      module address for `imports`
#
# list, show and imports change nothing.
# only `delete` does, and only after the guards below and a typed confirmation.
#
# WHY THIS DOES NOT IMPORT FOR YOU
# `terraform import` writes OWNERSHIP into state. Import a resource whose
# settings do not exactly match the configuration and the next apply mutates
# it, and the next destroy deletes it. For test debris, deleting is almost
# always the right answer and importing almost never is -- an import adopts a
# half-built resource nobody has inspected and carries it into the next apply.
# So `imports` PRINTS commands for a human to read and choose from; it never
# runs one.
#
# A NOTE ON `-o tsv` AND --query
# Every --query below uses the multiselect LIST form [].[a,b,c], never the
# hash form [].{k:a,...}. With `-o tsv` the hash form does NOT emit columns in
# the order you wrote them: jmespath returns a plain dict and the CLI's tsv
# writer sorts it (`sorted(data.items())`, deliberately, "to make the output
# stable"). So [].{type:type,name:name} arrives NAME first. Anything that then
# reads columns by position is silently wrong -- and stays wrong under a mock
# built to match the code rather than the service. Prefer [].[a,b,c], which has
# no dict to sort, or query one scalar at a time.

set -uo pipefail

MODE="${1:-}"
[ -n "$MODE" ] && shift

PREFIX="${HB_NAME_PREFIX:-}"
SUB="${HB_SUBSCRIPTION_ID:-}"
HOSTNAME_GUARD="${HB_PUBLIC_HOSTNAME:-}"
# Default matches the shape a root module gets from the sat-azure-ha /
# asm-azure-ha wrapper: your `module "x"` block, then the wrapper's internal
# `module "this"`. Override with --module if you named yours differently or
# call the tier module directly.
MODULE_ADDR="${HB_MODULE_ADDR:-module.hailbytes.module.this}"
ALL=0
RG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)       [ $# -ge 2 ] || { echo "--prefix needs a value" >&2; exit 2; }; PREFIX="$2"; shift ;;
        --prefix=*)     PREFIX="${1#--prefix=}" ;;
        --subscription) [ $# -ge 2 ] || { echo "--subscription needs a value" >&2; exit 2; }; SUB="$2"; shift ;;
        --subscription=*) SUB="${1#--subscription=}" ;;
        --hostname)     [ $# -ge 2 ] || { echo "--hostname needs a value" >&2; exit 2; }; HOSTNAME_GUARD="$2"; shift ;;
        --hostname=*)   HOSTNAME_GUARD="${1#--hostname=}" ;;
        --module)       [ $# -ge 2 ] || { echo "--module needs a value" >&2; exit 2; }; MODULE_ADDR="$2"; shift ;;
        --module=*)     MODULE_ADDR="${1#--module=}" ;;
        --all)          ALL=1 ;;
        -h|--help)      MODE="help" ;;
        -*)             echo "unknown option: $1" >&2; exit 2 ;;
        *)              [ -z "$RG" ] && RG="$1" || { echo "unexpected argument: $1" >&2; exit 2; } ;;
    esac
    shift
done

usage() {
    sed -n '/^#   \.\/quickstart\/sweep-azure\.sh list/,/^# only .delete. does/p' "${BASH_SOURCE[0]}" \
        | sed 's/^# \{0,1\}//'
}

case "$MODE" in
    help|-h|--help|"") usage; exit 0 ;;
    list|show|imports|delete) ;;
    *) echo "unknown command: ${MODE}" >&2; echo >&2; usage >&2; exit 2 ;;
esac

FAILS=0
bad()  { printf 'BLOCKED  %s\n' "$*"; FAILS=$((FAILS+1)); }
warn() { printf 'WARNING  %s\n' "$*"; }
note() { printf '         %s\n' "$*"; }

# `az_` hides stderr so a missing optional resource does not spew. That makes
# require_subscription below mandatory: without it a failed lookup returns
# empty and `list` reports "nothing to clean up" -- a false all-clear on
# precisely the question being asked.
az_() {
    if [ -n "$SUB" ]; then az "$@" --subscription "$SUB" 2>/dev/null
    else az "$@" 2>/dev/null; fi
}

SUB_NAME=""
require_subscription() {
    local out rc
    if [ -n "$SUB" ]; then
        out="$(az account show --subscription "$SUB" --query name -o tsv 2>&1)"; rc=$?
    else
        out="$(az account show --query name -o tsv 2>&1)"; rc=$?
    fi
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
        echo "ERROR: cannot read the Azure subscription." >&2
        printf '%s\n' "$out" | sed 's/^/       /' >&2
        echo "       In Cloud Shell you are normally already logged in; otherwise" >&2
        echo "       run 'az login'. Until this call works, an empty result below" >&2
        echo "       would mean 'could not look', not 'nothing there'." >&2
        exit 1
    fi
    SUB_NAME="$out"
    [ -n "$SUB" ] || SUB="$(az account show --query id -o tsv 2>/dev/null)"
}

# ---------------------------------------------------------------------------
# Protection audit. Two severities, deliberately:
#
#   bad()  -> BLOCKS the delete. One thing does this: the hostname you passed
#             currently resolving to an address inside the group. That is both
#             unrecoverable and immediately user-visible, so it is not a
#             judgement call.
#   warn() -> reported, delete still possible after confirmation. A lock (Azure
#             refuses server-side anyway, so blocking here would only hide the
#             real reason), a storage account, or a public IP nothing points at.
#
# The public-IP check is here because Azure has NO undelete for a public IP.
# Deleting a resource group that holds a reserved address loses the address
# permanently and forces a DNS change.
# ---------------------------------------------------------------------------
audit_protection() {
    local rg="$1" risky=0

    local locks
    locks="$(az_ lock list -g "$rg" --query "[].[name,level]" -o tsv | tr '\t' '/' | tr '\n' ' ')"
    if [ -n "${locks// /}" ]; then
        warn "locked: ${locks% }"
        note "The delete will fail. That is the lock doing its job -- somebody"
        note "protected this deliberately. Find out why before removing it."
        risky=1
    fi

    local pips
    pips="$(az_ network public-ip list -g "$rg" --query "[].[ipAddress,name,ipConfiguration.id]" -o tsv)"
    if [ -n "${pips//[[:space:]]/}" ]; then
        warn "holds $(printf '%s\n' "$pips" | grep -c .) public IP(s) -- Azure cannot undelete these"
        local ip name used host fwd
        while IFS=$'\t' read -r ip name used; do
            [ -z "$ip" ] && continue
            printf '         %-16s %-30s %s\n' "$ip" "$name" \
                "$([ -n "$used" ] && [ "$used" != "None" ] && echo in-use || echo unattached)"
            host="$(getent hosts "$ip" 2>/dev/null | awk '{print $2}' | head -1)"
            [ -n "$host" ] && { printf '         %-16s reverse-resolves to %s\n' "" "$host"; risky=1; }
            if [ -n "$HOSTNAME_GUARD" ]; then
                fwd="$(getent hosts "$HOSTNAME_GUARD" 2>/dev/null | awk '{print $1}' | head -1)"
                if [ "$fwd" = "$ip" ]; then
                    bad "${HOSTNAME_GUARD} currently resolves to ${ip}, which is in this group"
                    note "Deleting the group destroys that address and Azure cannot give"
                    note "it back. Move it somewhere safe first:"
                    note "  az group create -n keep-rg -l <region>"
                    note "  az resource move --destination-group keep-rg \\"
                    note "    --ids \$(az network public-ip show -g ${rg} -n ${name} --query id -o tsv)"
                    note "  az lock create -n keep --lock-type CanNotDelete -g keep-rg"
                    risky=1
                fi
            fi
        done <<< "$pips"
    fi

    local sa
    sa="$(az_ storage account list -g "$rg" --query "[].name" -o tsv | tr '\n' ' ')"
    [ -n "${sa// /}" ] && {
        warn "holds storage account(s): ${sa% }"
        note "If one of these holds terraform state or backups, deleting loses it."
        risky=1
    }
    return "$risky"
}

matching_groups() {
    local all
    all="$(az_ group list --query "[].name" -o tsv)"
    if [ "$ALL" -eq 1 ] || [ -z "$PREFIX" ]; then
        printf '%s' "$all"
    else
        printf '%s' "$all" | grep -F "$PREFIX"
    fi
}

cmd_list() {
    require_subscription
    echo "=============================================================="
    echo " Azure leftovers — ${SUB_NAME}"
    echo "=============================================================="
    local all total rgs
    all="$(az_ group list --query "[].name" -o tsv)"
    total="$(printf '%s\n' "$all" | grep -c .)"
    if [ "$ALL" -eq 1 ] || [ -z "$PREFIX" ]; then
        echo "All ${total} resource group(s) in the subscription."
        rgs="$all"
    else
        echo "Groups whose name contains '${PREFIX}', of ${total} in the subscription."
        rgs="$(printf '%s\n' "$all" | grep -F "$PREFIX")"
    fi
    echo

    # "Matched nothing" and "there is nothing" are different answers and only
    # one of them means you are clean. Never conflate them.
    if [ -z "${rgs//[[:space:]]/}" ]; then
        if [ "$total" -eq 0 ]; then
            echo "The subscription has no resource groups at all. Nothing to clean up."
        else
            echo "No group name contains '${PREFIX}'."
            echo
            echo "This is NOT an all-clear -- it means the filter matched nothing."
            echo "The ${total} group(s) that do exist:"
            printf '%s\n' "$all" | sed 's/^/  /'
            echo
            echo "Re-run with a filter that matches, or with --all."
        fi
        return 0
    fi

    printf '  %-36s %6s  %-7s %s\n' "RESOURCE GROUP" "COUNT" "LOCKED" "NOTES"
    printf '  %s\n' "--------------------------------------------------------------------------"
    local rg n locked pip notes
    while read -r rg; do
        [ -z "$rg" ] && continue
        n="$(az_ resource list -g "$rg" --query "length(@)" -o tsv)"
        locked="$(az_ lock list -g "$rg" --query "length(@)" -o tsv)"
        pip="$(az_ network public-ip list -g "$rg" --query "length(@)" -o tsv)"
        notes=""
        [ "${pip:-0}" -gt 0 ] 2>/dev/null && notes="${pip} public IP(s) -- unrecoverable if deleted"
        [ "${n:-0}" = "0" ] && notes="empty"
        printf '  %-36s %6s  %-7s %s\n' "$rg" "${n:-?}" \
            "$([ "${locked:-0}" -gt 0 ] 2>/dev/null && echo yes || echo no)" "$notes"
    done <<< "$rgs"

    echo
    echo "Next:  sweep-azure.sh show <rg>      what is inside"
    echo "       sweep-azure.sh imports <rg>   print import commands to review"
    echo "       sweep-azure.sh delete <rg>    delete it, with guards"
}

cmd_show() {
    [ -n "$RG" ] || { echo "usage: sweep-azure.sh show <resource-group>" >&2; exit 2; }
    require_subscription
    az_ group show -n "$RG" >/dev/null || { echo "ERROR: no such resource group: ${RG}" >&2; exit 1; }

    echo "=============================================================="
    echo " Contents of ${RG}"
    echo "=============================================================="
    az_ resource list -g "$RG" --query "[].[type,name]" -o tsv \
        | sort | awk -F'\t' '{printf "  %-54s %s\n", $1, $2}'
    local n; n="$(az_ resource list -g "$RG" --query "length(@)" -o tsv)"
    echo "  -- ${n:-0} resource(s) --"
    echo

    # Child resources do NOT appear in `az resource list`. A diagnostic setting
    # on a load balancer is one, and is exactly the kind of leftover that fails
    # an apply with "already exists".
    echo "--------------------------------------------------------------"
    echo " Child resources (invisible to 'az resource list')"
    echo "--------------------------------------------------------------"
    local lb d found=0
    for lb in $(az_ network lb list -g "$RG" --query "[].name" -o tsv); do
        d="$(az_ monitor diagnostic-settings list \
              --resource "/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.Network/loadBalancers/${lb}" \
              --query "value[].name" -o tsv | tr '\n' ' ')"
        [ -n "${d// /}" ] && { printf '  diagnostic-setting on lb/%-26s %s\n' "$lb" "${d% }"; found=1; }
    done
    [ "$found" -eq 0 ] && echo "  none found"
    echo

    echo "--------------------------------------------------------------"
    echo " What protects it"
    echo "--------------------------------------------------------------"
    audit_protection "$RG" || true
    [ "$FAILS" -eq 0 ] && echo "No blocking protections detected."
    return 0
}

cmd_imports() {
    [ -n "$RG" ] || { echo "usage: sweep-azure.sh imports <resource-group>" >&2; exit 2; }
    require_subscription
    az_ group show -n "$RG" >/dev/null || { echo "ERROR: no such resource group: ${RG}" >&2; exit 1; }

    echo "=============================================================="
    echo " terraform import commands for ${RG} — REVIEW BEFORE RUNNING"
    echo "=============================================================="
    echo "These are PRINTED, not run. An import adopts a resource into state;"
    echo "the next apply may then modify it and the next destroy will delete"
    echo "it. Only import something you built and intend to keep. For test"
    echo "debris, prefer:  sweep-azure.sh delete ${RG}"
    echo
    echo "# Run these from the directory holding your root module, with the same"
    echo "# variables the apply uses (a terraform.tfvars or -var-file). Root"
    echo "# variables with no default otherwise stop each command with"
    echo "#   Error: No value for required variable"
    echo "# which looks like a broken import command and is not one."
    echo "#"
    echo "# Module addresses below assume ${MODULE_ADDR}."
    echo "# Override with --module if your root module names it differently."
    echo "# A wrong address fails immediately with \"does not exist in the"
    echo "# configuration\", before Azure is contacted."
    echo

    local M="$MODULE_ADDR"
    printf 'terraform import \\\n  azurerm_resource_group.main \\\n  /subscriptions/%s/resourceGroups/%s\n\n' "$SUB" "$RG"

    local id name child addr d
    for name in $(az_ network lb list -g "$RG" --query "[].name" -o tsv); do
        id="/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.Network/loadBalancers/${name}"
        printf 'terraform import \\\n  %s.azurerm_lb.main \\\n  %s\n\n' "$M" "$id"

        # The load balancer's CHILDREN have to come with it. Import the lb
        # alone and the next apply tries to create the pool, probes and rules
        # that already exist -- the same failure one layer down. The inline
        # frontend_ip_configuration needs no import of its own.
        #
        # Only what Azure actually reports is emitted: a half-built lb may have
        # a pool and no rules, and a command for something that does not exist
        # fails confusingly in the middle of a list.
        for child in $(az_ network lb address-pool list -g "$RG" --lb-name "$name" --query "[].name" -o tsv); do
            case "$child" in
                backend) addr="${M}.azurerm_lb_backend_address_pool.main" ;;
                *) warn "unrecognised backend pool '${child}' -- no module address for it"; continue ;;
            esac
            printf 'terraform import \\\n  %s \\\n  %s/backendAddressPools/%s\n\n' "$addr" "$id" "$child"
        done
        for child in $(az_ network lb probe list -g "$RG" --lb-name "$name" --query "[].name" -o tsv); do
            case "$child" in
                health) addr="${M}.azurerm_lb_probe.https" ;;
                phish)  addr="${M}.azurerm_lb_probe.phish[0]" ;;
                *) warn "unrecognised probe '${child}' -- no module address for it"; continue ;;
            esac
            printf "terraform import \\\\\n  '%s' \\\\\n  '%s/probes/%s'\n\n" "$addr" "$id" "$child"
        done
        for child in $(az_ network lb rule list -g "$RG" --lb-name "$name" --query "[].name" -o tsv); do
            case "$child" in
                https) addr="${M}.azurerm_lb_rule.https" ;;
                phish) addr="${M}.azurerm_lb_rule.phish[0]" ;;
                *) warn "unrecognised rule '${child}' -- no module address for it"; continue ;;
            esac
            printf "terraform import \\\\\n  '%s' \\\\\n  '%s/loadBalancingRules/%s'\n\n" "$addr" "$id" "$child"
        done

        for d in $(az_ monitor diagnostic-settings list --resource "$id" --query "value[].name" -o tsv); do
            # NOTE the ID form for a diagnostic setting:
            #   <target-resource-id>|<setting-name>
            # Both the pipe and the [0] must be single-quoted for the shell.
            printf "terraform import \\\\\n  '%s.azurerm_monitor_diagnostic_setting.lb[0]' \\\\\n  '%s|%s'\n\n" "$M" "$id" "$d"
        done
    done

    for name in $(az_ keyvault list -g "$RG" --query "[].name" -o tsv); do
        printf 'terraform import \\\n  %s.azurerm_key_vault.main \\\n  /subscriptions/%s/resourceGroups/%s/providers/Microsoft.KeyVault/vaults/%s\n\n' \
            "$M" "$SUB" "$RG" "$name"
    done
    for name in $(az_ network vnet list -g "$RG" --query "[].name" -o tsv); do
        printf 'terraform import \\\n  module.network.azurerm_virtual_network.main \\\n  /subscriptions/%s/resourceGroups/%s/providers/Microsoft.Network/virtualNetworks/%s\n\n' \
            "$SUB" "$RG" "$name"
    done
}

cmd_delete() {
    [ -n "$RG" ] || { echo "usage: sweep-azure.sh delete <resource-group>" >&2; exit 2; }
    require_subscription
    az_ group show -n "$RG" >/dev/null || { echo "ERROR: no such resource group: ${RG}" >&2; exit 1; }

    echo "=============================================================="
    echo " About to DELETE ${RG}"
    echo "=============================================================="
    local n; n="$(az_ resource list -g "$RG" --query "length(@)" -o tsv)"
    echo "${n:-0} resource(s) will be destroyed. This cannot be undone."
    echo
    audit_protection "$RG"
    local risky=$?

    if [ "$FAILS" -gt 0 ]; then
        echo
        echo "Refusing to delete -- see the blocked item(s) above."
        echo "Resolve them, or move the irreplaceable resource out first."
        return 1
    fi
    [ "$risky" -ne 0 ] && { echo; echo "Proceed only if you understand the warnings above."; }

    echo
    if [ ! -t 0 ]; then
        echo "Refusing to delete without a terminal to confirm on." >&2
        echo "Run this interactively. There is deliberately no --force." >&2
        return 1
    fi
    printf 'Type the resource group name to confirm: '
    local answer; read -r answer
    if [ "$answer" != "$RG" ]; then
        echo "'${answer}' does not match '${RG}' -- nothing deleted."
        return 0
    fi
    if az_ group delete --name "$RG" --yes --no-wait >/dev/null; then
        echo "Delete requested for ${RG}. Azure continues in the background."
    else
        echo "Delete request failed. A lock is the usual reason." >&2
        return 1
    fi
}

case "$MODE" in
    list)    cmd_list ;;
    show)    cmd_show ;;
    imports) cmd_imports ;;
    delete)  cmd_delete ;;
esac
