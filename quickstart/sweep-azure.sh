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
#   --module ADDR       HB_MODULE_ADDR      tier module address for `imports`
#   --network-module A  HB_NETWORK_ADDR     network module address for `imports`
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
# The network module is a sibling of the product wrapper, not nested inside it,
# so it needs its own address. quickstart/azure-ha and azure-ha-byoip both call
# it `module "network"`.
NETWORK_ADDR="${HB_NETWORK_ADDR:-module.network}"
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
        --network-module)   [ $# -ge 2 ] || { echo "--network-module needs a value" >&2; exit 2; }; NETWORK_ADDR="$2"; shift ;;
        --network-module=*) NETWORK_ADDR="${1#--network-module=}" ;;
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

# ---------------------------------------------------------------------------
# Import emitters
# ---------------------------------------------------------------------------
# One printf for every import command, so quoting is decided once. Both operands
# are single-quoted: several Azure id forms contain characters the shell would
# otherwise eat -- a pipe in composite ids, and [0] / ["key"] in the addresses.
emit() {  # emit <terraform-address> <azure-id>
    printf "terraform import \\\\\n  '%s' \\\\\n  '%s'\n\n" "$1" "$2"
}

# Full ARM id for something in the target group.
rid() {  # rid <provider/type> <name>
    printf '/subscriptions/%s/resourceGroups/%s/providers/%s/%s' "$SUB" "$RG" "$1" "$2"
}

section()   { printf '# ----- %s -----\n\n' "$*"; }
note_line() { printf '# NOTE: %s\n\n' "$*"; }

# A diagnostic setting's id is <target-resource-id>|<setting-name>. Emitted for
# whatever target is passed, since four different resources carry one.
emit_diagnostics() {  # emit_diagnostics <target-id> <address>
    local d
    for d in $(az_ monitor diagnostic-settings list --resource "$1" --query "value[].name" -o tsv); do
        emit "$2" "${1}|${d}"
    done
}

# The generated values.
#
# random_password and random_id produce the database password, the session keys
# and the initial admin password, and the module writes all three into Key Vault
# at deploy time. That makes Key Vault the only surviving copy after a state
# loss, and importing these from it is what makes a recovery rotate NOTHING.
#
# Skip this and the first apply generates fresh values: the database password
# rotates (Terraform updates the server and the secret together, so they stay
# consistent, but each VM needs a restart to re-read it) and every session key
# rotates, signing all users out.
#
# The values are secrets, so the commands are emitted with a shell substitution
# rather than the value itself -- nothing sensitive is printed or scrolled back.
emit_random_imports() {  # emit_random_imports <vault-name>
    local vault="$1" have=0 s
    for s in hailbytes-db-password hailbytes-session-keys hailbytes-admin-initial-password; do
        az_ keyvault secret show --vault-name "$vault" -n "$s" --query id -o tsv >/dev/null && have=1
    done
    [ "$have" -eq 1 ] || return 0

    cat <<EOF
# The generated values, read back out of Key Vault so nothing rotates.
# Run these as shown: the substitutions keep the secrets off your screen and
# out of your shell history.
KV=${vault}

terraform import '${MODULE_ADDR}.random_password.db' \\
  "\$(az keyvault secret show --vault-name "\$KV" -n hailbytes-db-password --query value -o tsv)"

terraform import '${MODULE_ADDR}.random_password.admin_initial' \\
  "\$(az keyvault secret show --vault-name "\$KV" -n hailbytes-admin-initial-password --query value -o tsv)"

# Session keys are stored as "<hash hex>:<enc hex>" and random_id imports
# base64url, so convert each half.
SESSION="\$(az keyvault secret show --vault-name "\$KV" -n hailbytes-session-keys --query value -o tsv)"
hex2b64url() { printf '%s' "\$1" | xxd -r -p | base64 | tr '+/' '-_' | tr -d '='; }

terraform import '${MODULE_ADDR}.random_id.session_hash_key' "\$(hex2b64url "\${SESSION%%:*}")"
terraform import '${MODULE_ADDR}.random_id.session_enc_key'  "\$(hex2b64url "\${SESSION##*:}")"

# CHECK THE PLAN after these. The random provider's importers do not
# reconstruct every argument from the id, so a random_password can still plan a
# replacement against a configuration that sets length or special. If it does,
# accept the rotation -- see "If values rotate anyway" in
# docs/AZURE_STATE_RECOVERY.md -- rather than hand-editing state.

EOF
}

# Role assignments, matched to module addresses by role name and principal.
#
# An assignment that exists but is missing from state fails the next apply with
# RoleAssignmentExists, naming a GUID and not the grant. So they have to be
# imported, and the GUID alone says nothing about which module resource made it.
#
# Role name narrows it; the principal finishes the job. VM managed identities
# are resolvable to an index here, so those are emitted complete. Anything else
# is printed WITH its principal and left for a human, because guessing an index
# wrong adopts one grant under another's address and the mistake only surfaces
# on a later apply.
emit_role_assignments() {
    local scope_id vm_principals=() name p role guid i idx

    for name in $(az_ vm list -g "$RG" --query "[].name" -o tsv | sort); do
        case "$name" in *-db-vm) continue ;; esac
        p="$(az_ vm show -g "$RG" -n "$name" --query "identity.principalId" -o tsv)"
        [ -n "$p" ] && vm_principals+=("$p")
    done

    for scope_id in \
        $(az_ keyvault list -g "$RG" --query "[].id" -o tsv) \
        $(az_ storage account list -g "$RG" --query "[].id" -o tsv)
    do
        # -o tsv with a multiselect LIST form: columns arrive in written order.
        while IFS=$'\t' read -r role guid p; do
            [ -n "$guid" ] || continue
            idx=""
            for i in "${!vm_principals[@]}"; do
                # First match, then stop. Last-match-wins would place the grant
                # under the highest matching index rather than the real one.
                if [ "${vm_principals[$i]}" = "$p" ]; then idx="$i"; break; fi
            done
            case "${role}|${idx:+vm}" in
                "Key Vault Secrets Officer|")            addr="${MODULE_ADDR}.azurerm_role_assignment.kv_secret_writer" ;;
                "Key Vault Secrets User|vm")             addr="${MODULE_ADDR}.azurerm_role_assignment.vm_kv_secrets_user[${idx}]" ;;
                "Storage Blob Data Contributor|vm")      addr="${MODULE_ADDR}.azurerm_role_assignment.vm_backup_writer[${idx}]" ;;
                "Key Vault Crypto Officer|")             addr="${MODULE_ADDR}.azurerm_role_assignment.kv_crypto_officer[0]" ;;
                "Key Vault Secrets User|")
                    addr="${MODULE_ADDR}.azurerm_role_assignment.kv_secret_readers[\"${p}\"]"
                    note_line "principal ${p} is not a VM identity. If it is the DB VM this is azurerm_role_assignment.db_vm_kv_reader[0]; if it came from key_vault_reader_principal_ids the address above is right." ;;
                "Key Vault Crypto Service Encryption User|")
                    addr="${MODULE_ADDR}.azurerm_role_assignment.des_kv_crypto_user[0]"
                    note_line "principal ${p}: this role is used TWICE (des_kv_crypto_user and cmk_kv_crypto_user). Check which identity it is before importing." ;;
                *) warn "unrecognised role assignment: '${role}' for principal ${p} -- no module address for it"; continue ;;
            esac
            emit "$addr" "${scope_id}/providers/Microsoft.Authorization/roleAssignments/${guid}"
        done < <(az_ role assignment list --scope "$scope_id" \
                   --query "[].[roleDefinitionName,name,principalId]" -o tsv)
    done
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
        local ip name used host
        while IFS=$'\t' read -r ip name used; do
            [ -z "$ip" ] && continue
            printf '         %-16s %-30s %s\n' "$ip" "$name" \
                "$([ -n "$used" ] && [ "$used" != "None" ] && echo in-use || echo unattached)"
            host="$(getent hosts "$ip" 2>/dev/null | awk '{print $2}' | head -1)"
            [ -n "$host" ] && { printf '         %-16s reverse-resolves to %s\n' "" "$host"; risky=1; }
            if [ -n "$HOSTNAME_GUARD" ]; then
                # EVERY address the name resolves to, not just the first.
                # `getent hosts` prints a single line, and on a dual-stack host
                # that line is usually the AAAA -- so a hostname with both an
                # AAAA and an A record would slip past this guard even when the
                # A record points straight at an address in this group, which is
                # the one case the guard exists for. `getent ahosts` lists both
                # families; -qxF matches a whole line literally so 10.0.0.1
                # cannot match 110.0.0.10.
                if getent ahosts "$HOSTNAME_GUARD" 2>/dev/null \
                     | awk '{print $1}' | sort -u | grep -qxF "$ip"; then
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
    echo "# Module addresses below assume:"
    echo "#   tier module     ${MODULE_ADDR}"
    echo "#   network module  ${NETWORK_ADDR}"
    echo "# Override with --module / --network-module if your root module names"
    echo "# them differently. A wrong address fails immediately with \"does not"
    echo "# exist in the configuration\", before Azure is contacted."
    echo "#"
    echo "# THE FINISH LINE IS A CLEAN PLAN. Import everything below, then run"
    echo "# terraform plan and keep working until it reports no changes. Until"
    echo "# then an apply is not safe. See docs/AZURE_STATE_RECOVERY.md."
    echo

    local M="$MODULE_ADDR"
    local N="$NETWORK_ADDR"
    local id name child addr d vnet_id nsg_id

    section "resource group"
    emit 'azurerm_resource_group.main' "/subscriptions/${SUB}/resourceGroups/${RG}"

    # ----------------------------------------------------------------- network
    #
    # Subnet and NSG addresses are chosen by NAME SUFFIX, because that is the
    # only thing that distinguishes the network module's resources from the
    # workload module's inside one group. One suffix is genuinely ambiguous:
    # "-lb-nsg" is the name BOTH modules give their load-balancer NSG. The
    # quickstarts pass associate_subnet_nsgs = false precisely so the network
    # module creates none (Azure would reject the duplicate name anyway), so it
    # is emitted as the tier module's and flagged.
    section "network"
    for name in $(az_ network vnet list -g "$RG" --query "[].name" -o tsv); do
        vnet_id="$(rid Microsoft.Network/virtualNetworks "$name")"
        emit "${N}.azurerm_virtual_network.main" "$vnet_id"

        for child in $(az_ network vnet subnet list -g "$RG" --vnet-name "$name" --query "[].name" -o tsv); do
            case "$child" in
                *-lb)            addr="${N}.azurerm_subnet.lb" ;;
                *-workload)      addr="${N}.azurerm_subnet.workload" ;;
                *-db)            addr="${N}.azurerm_subnet.db" ;;
                *-appgw-subnet)  addr='azurerm_subnet.appgw[0]'
                                 note_line "'${child}' is created by the ROOT module in quickstart/azure-ha-byoip, not by a module." ;;
                *) warn "unrecognised subnet '${child}' -- no module address for it"; continue ;;
            esac
            emit "$addr" "${vnet_id}/subnets/${child}"

            # The association imports under the SUBNET's id, not an id of its
            # own. Only emitted when something is actually attached.
            if [ -n "$(az_ network vnet subnet show -g "$RG" --vnet-name "$name" -n "$child" --query "networkSecurityGroup.id" -o tsv)" ]; then
                case "$child" in
                    *-lb)       addr="${M}.azurerm_subnet_network_security_group_association.lb" ;;
                    *-workload) addr="${M}.azurerm_subnet_network_security_group_association.vm[0]" ;;
                    *-db)       addr="${N}.azurerm_subnet_network_security_group_association.db[0]" ;;
                    *) addr="" ;;
                esac
                [ -n "$addr" ] && emit "$addr" "${vnet_id}/subnets/${child}"
            fi
            if [ -n "$(az_ network vnet subnet show -g "$RG" --vnet-name "$name" -n "$child" --query "natGateway.id" -o tsv)" ]; then
                emit "${N}.azurerm_subnet_nat_gateway_association.workload[0]" "${vnet_id}/subnets/${child}"
            fi
        done
    done

    for name in $(az_ network nsg list -g "$RG" --query "[].name" -o tsv); do
        nsg_id="$(rid Microsoft.Network/networkSecurityGroups "$name")"
        case "$name" in
            *-db-vm-nsg)   addr="${M}.azurerm_network_security_group.db_vm[0]" ;;
            *-vm-nsg)      addr="${M}.azurerm_network_security_group.vm[0]" ;;
            *-lb-nsg)      addr="${M}.azurerm_network_security_group.lb"
                           note_line "'${name}' is ambiguous: both the tier and network modules use this name." ;;
            *-workload-nsg) addr="${N}.azurerm_network_security_group.workload[0]" ;;
            *-db-nsg)      addr="${N}.azurerm_network_security_group.db[0]" ;;
            *) warn "unrecognised NSG '${name}' -- no module address for it"; continue ;;
        esac
        emit "$addr" "$nsg_id"

        # Rule addresses carry the for_each key, which for the CIDR-driven rules
        # is the INDEX of the CIDR in allowed_cidrs / phish_allowed_cidrs. The
        # rule name ends in that index, so it can be read straight off.
        for child in $(az_ network nsg rule list -g "$RG" --nsg-name "$name" --query "[].name" -o tsv); do
            case "$child" in
                allow-https-*)
                    # Scoped to the lb NSG on purpose. The tier module puts the
                    # 443 rule only there; the vm NSG's admin rule is
                    # allow-admin-*. An allow-https-* found on any other NSG is
                    # not this module's, and placing it under lb_https_in would
                    # adopt a stranger's rule under our address.
                    case "$name" in
                        *-lb-nsg) addr="${M}.azurerm_network_security_rule.lb_https_in[\"${child##*-}\"]" ;;
                        *) warn "unexpected '${child}' on '${name}' -- the 443 rule belongs on the lb NSG"; continue ;;
                    esac ;;
                allow-phish-*)
                    case "$name" in
                        *-vm-nsg) addr="${M}.azurerm_network_security_rule.vm_phish_in[\"${child##*-}\"]" ;;
                        *)        addr="${M}.azurerm_network_security_rule.lb_phish_in[\"${child##*-}\"]" ;;
                    esac ;;
                allow-admin-*)  addr="${M}.azurerm_network_security_rule.vm_admin_in[\"${child##*-}\"]" ;;
                allow-lb-probe) addr="${M}.azurerm_network_security_rule.vm_probe_in[0]" ;;
                allow-pg-from-vmsubnet) addr="${M}.azurerm_network_security_rule.db_vm_pg_in[0]" ;;
                *) warn "unrecognised NSG rule '${name}/${child}' -- no module address for it"; continue ;;
            esac
            emit "$addr" "${nsg_id}/securityRules/${child}"
        done
    done

    for name in $(az_ network public-ip list -g "$RG" --query "[].name" -o tsv); do
        case "$name" in
            *-lb-pip)    addr="${M}.azurerm_public_ip.lb[0]" ;;
            *-appgw-pip) addr="${M}.azurerm_public_ip.appgw[0]" ;;
            *-nat-pip)   addr="${N}.azurerm_public_ip.nat[0]" ;;
            *) warn "unrecognised public IP '${name}' -- if you supplied it via public_ip_id or appgw_public_ip_id it is NOT managed by this module and must not be imported"; continue ;;
        esac
        emit "$addr" "$(rid Microsoft.Network/publicIPAddresses "$name")"
    done

    for name in $(az_ network nat gateway list -g "$RG" --query "[].name" -o tsv); do
        id="$(rid Microsoft.Network/natGateways "$name")"
        emit "${N}.azurerm_nat_gateway.main[0]" "$id"
        for child in $(az_ network nat gateway show -g "$RG" -n "$name" --query "publicIpAddresses[].id" -o tsv); do
            # Composite id: <nat-gateway-id>|<public-ip-id>
            emit "${N}.azurerm_nat_gateway_public_ip_association.main[0]" "${id}|${child}"
        done
    done

    # ------------------------------------------------------------ load balancer
    section "load balancer"
    for name in $(az_ network lb list -g "$RG" --query "[].name" -o tsv); do
        id="$(rid Microsoft.Network/loadBalancers "$name")"
        emit "${M}.azurerm_lb.main" "$id"

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
            emit "$addr" "${id}/backendAddressPools/${child}"
        done
        for child in $(az_ network lb probe list -g "$RG" --lb-name "$name" --query "[].name" -o tsv); do
            case "$child" in
                health) addr="${M}.azurerm_lb_probe.https" ;;
                phish)  addr="${M}.azurerm_lb_probe.phish[0]" ;;
                *) warn "unrecognised probe '${child}' -- no module address for it"; continue ;;
            esac
            emit "$addr" "${id}/probes/${child}"
        done
        for child in $(az_ network lb rule list -g "$RG" --lb-name "$name" --query "[].name" -o tsv); do
            case "$child" in
                https) addr="${M}.azurerm_lb_rule.https" ;;
                phish) addr="${M}.azurerm_lb_rule.phish[0]" ;;
                *) warn "unrecognised rule '${child}' -- no module address for it"; continue ;;
            esac
            emit "$addr" "${id}/loadBalancingRules/${child}"
        done
        emit_diagnostics "$id" "${M}.azurerm_monitor_diagnostic_setting.lb[0]"
    done

    for name in $(az_ network application-gateway list -g "$RG" --query "[].name" -o tsv); do
        id="$(rid Microsoft.Network/applicationGateways "$name")"
        emit "${M}.azurerm_application_gateway.main[0]" "$id"
        emit_diagnostics "$id" "${M}.azurerm_monitor_diagnostic_setting.appgw[0]"
    done

    # --------------------------------------------------------------- compute
    #
    # VM index matters: the module's count places element 0 in zone 1 and
    # element 1 in zone 2, and vm_names (when set) is in the same order. Sorting
    # by name reproduces the derived "-vm-1", "-vm-2" order but CANNOT be
    # trusted for a custom vm_names list, so the index is reported for review
    # rather than assumed correct.
    section "virtual machines"
    local i=0
    for name in $(az_ vm list -g "$RG" --query "[].name" -o tsv | sort); do
        id="$(rid Microsoft.Compute/virtualMachines "$name")"
        case "$name" in
            *-db-vm) addr="${M}.azurerm_linux_virtual_machine.db_vm[0]" ;;
            *)
                addr="${M}.azurerm_linux_virtual_machine.vm[${i}]"
                note_line "'${name}' assumed to be vm[${i}]. With a custom vm_names, CHECK the order: element 0 is zone 1."
                i=$((i+1)) ;;
        esac
        emit "$addr" "$id"

        for child in $(az_ vm extension list -g "$RG" --vm-name "$name" --query "[].name" -o tsv); do
            case "$child" in
                AADSSHLoginForLinux) emit "${M}.azurerm_virtual_machine_extension.aad_ssh_login[${i}]" "${id}/extensions/${child}" ;;
                *) warn "unrecognised VM extension '${name}/${child}' -- no module address for it" ;;
            esac
        done

        # <vm-id>/dataDisks/<disk-name>. The disk itself imports separately,
        # under its own resource id.
        for child in $(az_ vm show -g "$RG" -n "$name" --query "storageProfile.dataDisks[].name" -o tsv); do
            case "$name" in
                *-db-vm) addr="${M}.azurerm_virtual_machine_data_disk_attachment.db_data[0]" ;;
                *)       addr="${M}.azurerm_virtual_machine_data_disk_attachment.data[$((i-1))]" ;;
            esac
            emit "$addr" "${id}/dataDisks/${child}"
        done
    done

    i=0
    for name in $(az_ disk list -g "$RG" --query "[].name" -o tsv | sort); do
        case "$name" in
            *-db-data) addr="${M}.azurerm_managed_disk.db_data[0]" ;;
            *-data-*)  addr="${M}.azurerm_managed_disk.data[$(( ${name##*-} - 1 ))]" ;;
            *) warn "unrecognised disk '${name}' -- an OS disk needs no import of its own; it belongs to its VM"; continue ;;
        esac
        emit "$addr" "$(rid Microsoft.Compute/disks "$name")"
    done

    i=0
    for name in $(az_ network nic list -g "$RG" --query "[].name" -o tsv | sort); do
        id="$(rid Microsoft.Network/networkInterfaces "$name")"
        case "$name" in
            *-db-nic) addr="${M}.azurerm_network_interface.db_vm[0]" ;;
            *-nic-*)  addr="${M}.azurerm_network_interface.vm[$(( ${name##*-} - 1 ))]" ;;
            *) warn "unrecognised NIC '${name}' -- no module address for it"; continue ;;
        esac
        emit "$addr" "$id"

        # Composite id: <nic-id>/ipConfigurations/<config>|<pool-id>
        for child in $(az_ network nic show -g "$RG" -n "$name" --query "ipConfigurations[0].loadBalancerBackendAddressPools[].id" -o tsv); do
            emit "${M}.azurerm_network_interface_backend_address_pool_association.vm[$(( ${name##*-} - 1 ))]" \
                 "${id}/ipConfigurations/primary|${child}"
        done
        # Composite id: <nic-id>|<nsg-id>
        child="$(az_ network nic show -g "$RG" -n "$name" --query "networkSecurityGroup.id" -o tsv)"
        [ -n "$child" ] && emit "${M}.azurerm_network_interface_security_group_association.db_vm[0]" "${id}|${child}"
    done

    # ---------------------------------------------------------------- database
    section "database"
    for name in $(az_ postgres flexible-server list -g "$RG" --query "[].name" -o tsv); do
        id="$(rid Microsoft.DBforPostgreSQL/flexibleServers "$name")"
        emit "${M}.azurerm_postgresql_flexible_server.main[0]" "$id"
        for child in require_secure_transport log_min_duration_statement; do
            case "$child" in
                require_secure_transport)     addr="${M}.azurerm_postgresql_flexible_server_configuration.require_ssl[0]" ;;
                log_min_duration_statement)   addr="${M}.azurerm_postgresql_flexible_server_configuration.log_min_duration_statement[0]" ;;
            esac
            emit "$addr" "${id}/configurations/${child}"
        done
        emit "${M}.azurerm_postgresql_flexible_server_database.main[0]" "${id}/databases/hailbytes"
        for child in $(az_ lock list --resource "$id" --query "[].name" -o tsv); do
            emit "${M}.azurerm_management_lock.db[0]" "${id}/providers/Microsoft.Authorization/locks/${child}"
        done
        emit_diagnostics "$id" "${M}.azurerm_monitor_diagnostic_setting.postgres[0]"
    done

    # ------------------------------------------------------------------- cache
    section "cache"
    for name in $(az_ redis list -g "$RG" --query "[].name" -o tsv); do
        id="$(rid Microsoft.Cache/redis "$name")"
        emit "${M}.azurerm_redis_cache.main[0]" "$id"
        emit_diagnostics "$id" "${M}.azurerm_monitor_diagnostic_setting.redis[0]"
    done
    for name in $(az_ network private-endpoint list -g "$RG" --query "[].name" -o tsv); do
        case "$name" in
            *-redis-pe) addr="${M}.azurerm_private_endpoint.redis[0]" ;;
            *) warn "unrecognised private endpoint '${name}' -- no module address for it"; continue ;;
        esac
        emit "$addr" "$(rid Microsoft.Network/privateEndpoints "$name")"
    done
    for name in $(az_ network private-dns zone list -g "$RG" --query "[].name" -o tsv); do
        id="$(rid Microsoft.Network/privateDnsZones "$name")"
        case "$name" in
            privatelink.redis.cache.windows.net)     addr="${M}.azurerm_private_dns_zone.redis[0]" ;;
            privatelink.postgres.database.azure.com) addr="${N}.azurerm_private_dns_zone.postgres" ;;
            *) warn "unrecognised private DNS zone '${name}' -- no module address for it"; continue ;;
        esac
        emit "$addr" "$id"
        for child in $(az_ network private-dns link vnet list -g "$RG" -z "$name" --query "[].name" -o tsv); do
            case "$child" in
                *-redis-link)    addr="${M}.azurerm_private_dns_zone_virtual_network_link.redis[0]" ;;
                *-postgres-link) addr="${N}.azurerm_private_dns_zone_virtual_network_link.postgres" ;;
                *) warn "unrecognised DNS zone link '${child}' -- no module address for it"; continue ;;
            esac
            emit "$addr" "${id}/virtualNetworkLinks/${child}"
        done
    done

    # ------------------------------------------------------------- key vault
    #
    # The secrets matter more than they look. Their VALUES are the only surviving
    # copy of what random_password / random_id generated, so importing the
    # random_* resources from them is what makes a recovery rotate nothing. A
    # key vault secret imports under its VERSIONED data-plane URI.
    section "key vault"
    for name in $(az_ keyvault list -g "$RG" --query "[].name" -o tsv); do
        emit "${M}.azurerm_key_vault.main" "$(rid Microsoft.KeyVault/vaults "$name")"
        for child in $(az_ keyvault secret list --vault-name "$name" --query "[].name" -o tsv); do
            case "$child" in
                hailbytes-db-password)             addr="${M}.azurerm_key_vault_secret.db" ;;
                hailbytes-session-keys)            addr="${M}.azurerm_key_vault_secret.session_keys" ;;
                hailbytes-admin-initial-password)  addr="${M}.azurerm_key_vault_secret.admin_initial_password" ;;
                hailbytes-redis-access-key)        addr="${M}.azurerm_key_vault_secret.redis[0]" ;;
                *) warn "unrecognised secret '${child}' -- no module address for it"; continue ;;
            esac
            id="$(az_ keyvault secret show --vault-name "$name" -n "$child" --query id -o tsv)"
            [ -n "$id" ] && emit "$addr" "$id"
        done
        for child in $(az_ keyvault key list --vault-name "$name" --query "[].name" -o tsv); do
            case "$child" in
                *-disk-key) id="$(az_ keyvault key show --vault-name "$name" -n "$child" --query key.kid -o tsv)"
                            [ -n "$id" ] && emit "${M}.azurerm_key_vault_key.disk[0]" "$id" ;;
                *) warn "unrecognised key '${child}' -- no module address for it" ;;
            esac
        done
        emit_random_imports "$name"
    done

    for name in $(az_ identity list -g "$RG" --query "[].name" -o tsv); do
        case "$name" in
            *-cmk-id) emit "${M}.azurerm_user_assigned_identity.cmk[0]" "$(rid Microsoft.ManagedIdentity/userAssignedIdentities "$name")" ;;
            *) warn "unrecognised managed identity '${name}' -- no module address for it" ;;
        esac
    done
    for name in $(az_ disk-encryption-set list -g "$RG" --query "[].name" -o tsv); do
        emit "${M}.azurerm_disk_encryption_set.vm[0]" "$(rid Microsoft.Compute/diskEncryptionSets "$name")"
    done

    # ----------------------------------------------------------------- storage
    section "storage"
    for name in $(az_ storage account list -g "$RG" --query "[].name" -o tsv); do
        id="$(rid Microsoft.Storage/storageAccounts "$name")"
        case "$name" in
            *flowlog*|*flow*) addr="${N}.azurerm_storage_account.flow_logs[0]" ;;
            *) addr="${M}.azurerm_storage_account.backup[0]" ;;
        esac
        emit "$addr" "$id"
        [ "$addr" = "${M}.azurerm_storage_account.backup[0]" ] || continue

        emit "${M}.azurerm_storage_management_policy.backup[0]" "${id}/managementPolicies/default"
        for child in $(az_ storage container list --account-name "$name" --auth-mode login --query "[].name" -o tsv); do
            emit "${M}.azurerm_storage_container.backup[0]" "${id}/blobServices/default/containers/${child}"
            note_line "an immutability policy on '${child}' imports separately; see the azurerm_storage_container_immutability_policy docs for its id form."
        done
    done

    # ---------------------------------------------------------------- monitor
    section "monitoring"
    for name in $(az_ monitor log-analytics workspace list -g "$RG" --query "[].name" -o tsv); do
        emit "${M}.azurerm_log_analytics_workspace.main[0]" "$(rid Microsoft.OperationalInsights/workspaces "$name")"
    done
    for name in $(az_ monitor action-group list -g "$RG" --query "[].name" -o tsv); do
        emit "${M}.azurerm_monitor_action_group.alerts[0]" "$(rid Microsoft.Insights/actionGroups "$name")"
    done
    for name in $(az_ monitor metrics alert list -g "$RG" --query "[].name" -o tsv); do
        case "$name" in
            *-lb-unhealthy-backends) addr="${M}.azurerm_monitor_metric_alert.lb_unhealthy[0]" ;;
            *-appgw-5xx-rate)        addr="${M}.azurerm_monitor_metric_alert.appgw_5xx[0]" ;;
            *) warn "unrecognised metric alert '${name}' -- no module address for it"; continue ;;
        esac
        emit "$addr" "$(rid Microsoft.Insights/metricAlerts "$name")"
    done

    # ------------------------------------------------------- role assignments
    #
    # These are not optional. A role assignment that exists but is absent from
    # state fails the next apply with RoleAssignmentExists, and the message
    # names a GUID rather than the thing it grants.
    #
    # The GUID carries no hint of which module resource created it, so the role
    # name plus the principal is what identifies it. Where the principal is a
    # VM's managed identity the index is derivable and is filled in; everything
    # else is printed with its principal for a human to place.
    section "role assignments"
    emit_role_assignments

    section "after the imports"
    echo "# terraform plan"
    echo "#"
    echo "# Not a no-op yet? Fix the CONFIGURATION to match reality rather than"
    echo "# importing harder. The usual three:"
    echo "#   db_high_availability_mode  must say \"Disabled\" if HA was never enabled"
    echo "#   key_vault_name             must be the name actually deployed"
    echo "#   allowed_cidrs              order matters: the NSG rule for_each key"
    echo "#                              is the INDEX in this list"
    echo
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
