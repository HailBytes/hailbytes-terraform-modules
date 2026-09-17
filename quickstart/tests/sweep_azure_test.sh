#!/usr/bin/env bash
#
# Tests for quickstart/sweep-azure.sh, run against a mocked `az`.
#
# No Azure credentials are used or required: `az` is a shell function defined
# below and exported (`export -f`), so the script under test -- run as a real
# subprocess -- calls the mock instead of the real CLI.
#
# These target the two failure modes that would actually cost something:
#
#   1. A FALSE ALL-CLEAR. The script's whole job is answering "is there
#      debris?". `az_` hides stderr, so without a guard a failed lookup renders
#      as an empty result and the answer becomes "no" when the truth is "could
#      not look". An expired login is the common way in. T4/T5 pin that shut.
#
#   2. READING tsv COLUMNS BY THE WRONG POSITION. `az --query` with the
#      multiselect HASH form ([].{k:a,...}) and -o tsv emits columns sorted by
#      KEY, not in written order, because jmespath returns a plain dict and the
#      CLI's tsv writer sorts it. So [].{type:type,name:name} arrives NAME
#      first. T6 asserts a type is in the type column, and T15 asserts no hash
#      form has crept back in.
#
#      This class of bug is hard to see in review and invisible to a mock built
#      to match the code rather than the service, so the mock below answers the
#      exact --query the script sends and returns SORTED columns for the hash
#      form -- i.e. it reproduces the breakage rather than papering over it.
#
# Run: bash quickstart/tests/sweep_azure_test.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
SWEEP="${REPO}/quickstart/sweep-azure.sh"
[ -x "$SWEEP" ] || { echo "not executable: $SWEEP" >&2; exit 2; }

pass=0; fail=0

# ---------------------------------------------------------------- mock az ---
# Patterns are ordered most-specific first: 'ipConfiguration.id' contains
# '.id', so a loose pattern placed earlier would swallow it.
az() {
    local args="$*"
    case "$args" in
        # MOCK_SUB_FAIL is an expired login / invisible subscription. It must
        # break EVERY call, not just `account show` -- it is the COMBINATION
        # that produces the dangerous answer (a silent empty list read as "no
        # debris"). Failing only `account show` would let a test pass while
        # the false-all-clear path went unexercised.
        *"account show"*)
            [ "${MOCK_SUB_FAIL:-0}" = "1" ] && { echo "ERROR: (SubscriptionNotFound) The subscription could not be found." >&2; return 1; }
            case "$args" in
                *"--query id"*) echo "${MOCK_SUB_ID:-00000000-1111-2222-3333-444444444444}" ;;
                *)              echo "${MOCK_SUB_NAME:-HailBytes Test Lab}" ;;
            esac ;;
        # ----- resources `imports` enumerates ------------------------------
        # These sit ABOVE `group list` deliberately: "monitor action-group
        # list" CONTAINS "group list", so the loose pattern would answer it
        # with the resource-group names and the script would emit an action
        # group import per resource group. That is exactly the class of bug
        # the ordering comment at the top of this mock is about.
        *"monitor action-group list"*)  printf '%b' "${MOCK_ACTION_GROUPS-}" ;;
        *"monitor metrics alert list"*) printf '%b' "${MOCK_ALERTS-}" ;;
        *"monitor log-analytics workspace list"*) printf '%b' "${MOCK_LAW-}" ;;
        *"network vnet subnet list"*)   printf '%b' "${MOCK_SUBNETS-}" ;;
        *"network vnet subnet show"*"networkSecurityGroup.id"*) printf '%b' "${MOCK_SUBNET_NSG-}" ;;
        *"network vnet subnet show"*"natGateway.id"*) printf '%b' "${MOCK_SUBNET_NATGW-}" ;;
        *"network nsg rule list"*)      printf '%b' "${MOCK_NSG_RULES-}" ;;
        *"network nsg list"*)           printf '%b' "${MOCK_NSGS-}" ;;
        *"network public-ip list"*"[].name"*) printf '%b' "${MOCK_PIP_NAMES-}" ;;
        *"network nat gateway list"*)   printf '%b' "${MOCK_NATGWS-}" ;;
        *"network nat gateway show"*)   printf '%b' "${MOCK_NATGW_PIPS-}" ;;
        *"network application-gateway list"*) printf '%b' "${MOCK_APPGWS-}" ;;
        *"vm extension list"*)          printf '%b' "${MOCK_VM_EXTENSIONS-}" ;;
        *"vm show"*"dataDisks"*)        printf '%b' "${MOCK_VM_DATADISKS-}" ;;
        *"vm show"*"identity.principalId"*) printf '%b' "${MOCK_VM_PRINCIPALS-}" ;;
        *"vm list"*)                    printf '%b' "${MOCK_VMS-}" ;;
        *"disk-encryption-set list"*)   printf '%b' "${MOCK_DES-}" ;;
        *"disk list"*)                  printf '%b' "${MOCK_DISKS-}" ;;
        *"network nic show"*"loadBalancerBackendAddressPools"*) printf '%b' "${MOCK_NIC_POOLS-}" ;;
        *"network nic show"*"networkSecurityGroup.id"*) printf '%b' "${MOCK_NIC_NSG-}" ;;
        *"network nic list"*)           printf '%b' "${MOCK_NICS-}" ;;
        *"postgres flexible-server list"*) printf '%b' "${MOCK_PGS-}" ;;
        *"redis list"*)                 printf '%b' "${MOCK_REDIS-}" ;;
        *"network private-endpoint list"*) printf '%b' "${MOCK_PES-}" ;;
        *"network private-dns zone list"*) printf '%b' "${MOCK_DNS_ZONES-}" ;;
        *"network private-dns link vnet list"*) printf '%b' "${MOCK_DNS_LINKS-}" ;;
        *"keyvault secret list"*)       printf '%b' "${MOCK_KV_SECRETS-}" ;;
        *"keyvault secret show"*)       printf '%b' "${MOCK_KV_SECRET_ID-}" ;;
        *"keyvault key list"*)          printf '%b' "${MOCK_KV_KEYS-}" ;;
        *"keyvault key show"*)          printf '%b' "${MOCK_KV_KEY_ID-}" ;;
        *"identity list"*)              printf '%b' "${MOCK_IDENTITIES-}" ;;
        *"storage container list"*)     printf '%b' "${MOCK_CONTAINERS-}" ;;
        *"role assignment list"*)       printf '%b' "${MOCK_ROLE_ASSIGNMENTS-}" ;;
        *"lock list"*"[].name"*)        printf '%b' "${MOCK_DB_LOCKS-}" ;;
        *"group list"*)
            [ "${MOCK_SUB_FAIL:-0}" = "1" ] && { echo "ERROR: (SubscriptionNotFound)" >&2; return 1; }
            printf '%b' "${MOCK_GROUPS-hbtest-rg-01\nhbtest-rg-02\nhbtest-net-rg\nNetworkWatcherRG\n}" ;;
        *"group show"*)
            [ "${MOCK_RG_EXISTS:-1}" = "1" ] || { echo "ERROR: (ResourceGroupNotFound)" >&2; return 1; }
            echo "ok" ;;
        *"group delete"*)               return 0 ;;
        *"resource list"*"length(@)"*)  echo "${MOCK_RG_COUNT:-0}" ;;
        # MOCK_RESOURCES is in [].[type,name] order: TYPE first.
        *"resource list"*"[].[type,name]"*) printf '%b' "${MOCK_RESOURCES-}" ;;
        # The hash form the CLI would SORT -- name before type. Kept so a
        # regression to that form fails T6 instead of silently passing.
        *"resource list"*"[].{type:type,name:name}"*)
            printf '%b' "${MOCK_RESOURCES-}" | awk -F'\t' 'NF{printf "%s\t%s\n", $2, $1}' ;;
        *"lock list"*"length(@)"*)      [ -n "${MOCK_LOCK-}" ] && echo 1 || echo 0 ;;
        *"lock list"*"[].[name,level]"*) [ -n "${MOCK_LOCK-}" ] && printf '%b' "$MOCK_LOCK" ;;
        *"public-ip list"*"length(@)"*) printf '%b' "${MOCK_PIPS-}" | grep -c . ;;
        *"public-ip list"*"[].[ipAddress,name,ipConfiguration.id]"*) printf '%b' "${MOCK_PIPS-}" ;;
        *"storage account list"*"[].id"*) printf '%b' "${MOCK_STORAGE_IDS-}" ;;
        *"storage account list"*)       printf '%b' "${MOCK_STORAGE-}" ;;
        *"network lb list"*)            printf '%b' "${MOCK_LBS-}" ;;
        *"network lb address-pool list"*) printf '%b' "${MOCK_POOLS-}" ;;
        *"network lb probe list"*)      printf '%b' "${MOCK_PROBES-}" ;;
        *"network lb rule list"*)       printf '%b' "${MOCK_RULES-}" ;;
        *"diagnostic-settings list"*)   printf '%b' "${MOCK_DIAG-}" ;;
        *"keyvault list"*"[].id"*)      printf '%b' "${MOCK_KV_IDS-}" ;;
        *"keyvault list"*)              printf '%b' "${MOCK_KV-}" ;;
        *"network vnet list"*)          printf '%b' "${MOCK_VNETS-}" ;;
        # An unhandled call must NOT look like a successful empty result: that
        # is how a mock turns "I do not know" into "there is nothing there".
        *) echo "MOCK-UNHANDLED: $args" >&2; return 97 ;;
    esac
}
export -f az

# ------------------------------------------------------------------ checks --
has() {   # has <description> <needle> <haystack>
    if printf '%s' "$3" | grep -qF "$2"; then
        printf '  ok   %s\n' "$1"; pass=$((pass+1))
    else
        printf '  FAIL %s\n       expected to find: %q\n' "$1" "$2"
        printf '%s\n' "$3" | sed 's/^/       | /' | head -20
        fail=$((fail+1))
    fi
}
hasnt() { # hasnt <description> <needle> <haystack>
    if printf '%s' "$3" | grep -qF "$2"; then
        printf '  FAIL %s\n       should NOT contain: %q\n' "$1" "$2"
        printf '%s\n' "$3" | sed 's/^/       | /' | head -20
        fail=$((fail+1))
    else
        printf '  ok   %s\n' "$1"; pass=$((pass+1))
    fi
}

echo "sweep-azure.sh"

# --- list -------------------------------------------------------------------
o="$(MOCK_RG_COUNT=6 bash "$SWEEP" list --prefix hbtest 2>&1)"
has  "list finds matching groups"            "hbtest-rg-02" "$o"
hasnt "list omits non-matching groups"       "NetworkWatcherRG" "$o"

o="$(bash "$SWEEP" list --prefix nosuchthing 2>&1)"
has  "a filter that matches nothing is not an all-clear" "This is NOT an all-clear" "$o"
hasnt "and does not claim the subscription is clean"     "Nothing to clean up" "$o"
has  "and lists what does exist"             "hbtest-rg-01" "$o"

o="$(MOCK_GROUPS='' bash "$SWEEP" list --prefix hbtest 2>&1)"
has  "a genuinely empty subscription IS an all-clear" "no resource groups at all" "$o"

o="$(MOCK_SUB_FAIL=1 bash "$SWEEP" list --prefix hbtest 2>&1)"; rc=$?
has  "an unreadable subscription fails loudly"        "cannot read the Azure subscription" "$o"
hasnt "and never reports nothing to clean up"         "Nothing to clean up" "$o"
hasnt "and never claims zero groups"                  "no resource groups at all" "$o"
if [ "$rc" -ne 0 ]; then printf '  ok   and exits non-zero\n'; pass=$((pass+1))
else printf '  FAIL expected a non-zero exit, got %s\n' "$rc"; fail=$((fail+1)); fi

# --- show -------------------------------------------------------------------
o="$(MOCK_RG_COUNT=1 MOCK_RESOURCES='Microsoft.Network/loadBalancers\thb-lb\n' \
     MOCK_LBS='hb-lb\n' MOCK_DIAG='hb-lb-diag\n' \
     bash "$SWEEP" show hbtest-rg-01 2>&1)"
# Column ORDER: a TYPE must appear in the type column, not a name.
has "show puts the type in the type column" \
    "  Microsoft.Network/loadBalancers                        hb-lb" "$o"
has "show finds a child diagnostic setting" "diagnostic-setting on lb/hb-lb" "$o"

# --- delete guards ----------------------------------------------------------
o="$(MOCK_RG_COUNT=3 MOCK_LOCK='keep-ip\tCanNotDelete\n' bash "$SWEEP" delete hbtest-rg-01 2>&1)"
has "a lock is reported name/level"          "locked: keep-ip/CanNotDelete" "$o"
has "no terminal refuses the delete"         "Refusing to delete without a terminal" "$o"

o="$(MOCK_RG_COUNT=3 MOCK_STORAGE='hbteststate\n' bash "$SWEEP" delete hbtest-rg-01 2>&1)"
has "a storage account is reported"          "holds storage account(s): hbteststate" "$o"

# The one BLOCKING guard: a live hostname resolving into the group.
#
# `localhost` is deliberately the hostname here. It is dual-stack on a GitHub
# runner (::1 AND 127.0.0.1) and IPv4-only in some containers, and that
# difference caught a real bug: the guard read only the FIRST address `getent`
# returned, so on the runner it compared ::1, found no match, and let the
# delete through. A hostname with both an AAAA and an A record -- the A
# pointing into the group -- would have done the same in production.
#
# Assert the BLOCKING message specifically. "Refusing to delete" alone is not
# enough: the no-terminal guard emits "Refusing to delete without a terminal",
# so a substring assertion passes even when the blocking guard never fires --
# which is exactly how the bug above stayed hidden.
o="$(MOCK_RG_COUNT=3 MOCK_PIPS='127.0.0.1\thb-lb-pip\tNone\n' \
     bash "$SWEEP" delete hbtest-rg-01 --hostname localhost 2>&1)"
has  "a live hostname in the group blocks the delete" \
     "BLOCKED  localhost currently resolves to 127.0.0.1" "$o"
has  "and it stops for that reason, not for the tty"  "Refusing to delete -- see the blocked item" "$o"
hasnt "and it never reaches the confirmation prompt"  "Type the resource group name" "$o"
has  "and it says how to rescue the address"          "az resource move" "$o"

o="$(MOCK_RG_EXISTS=0 bash "$SWEEP" delete nope 2>&1)"
has "a missing group is an error, not a delete" "no such resource group" "$o"

# --- imports ----------------------------------------------------------------
o="$(MOCK_LBS='hb-lb\n' MOCK_DIAG='hb-lb-diag\n' MOCK_POOLS='backend\n' \
     MOCK_PROBES='health\nphish\n' MOCK_RULES='https\nphish\n' \
     MOCK_KV='hb-kv-a1b2\n' MOCK_VNETS='hb-vnet\n' \
     bash "$SWEEP" imports hbtest-rg-01 2>&1)"
has "imports the load balancer"          "module.hailbytes.module.this.azurerm_lb.main" "$o"
has "imports the backend pool"           "azurerm_lb_backend_address_pool.main" "$o"
has "imports both probes"                "azurerm_lb_probe.phish[0]" "$o"
has "imports both rules"                 "azurerm_lb_rule.phish[0]" "$o"
# A diagnostic setting's import ID is <target-resource-id>|<setting-name>.
has "diagnostic setting uses the id|name form" "loadBalancers/hb-lb|hb-lb-diag" "$o"
has "imports the key vault"              "azurerm_key_vault.main" "$o"
has "imports the vnet"                   "module.network.azurerm_virtual_network.main" "$o"
has "warns about missing tfvars"         "No value for required variable" "$o"
hasnt "and runs nothing itself"          "Delete requested" "$o"

o="$(MOCK_LBS='hb-lb\n' MOCK_POOLS='legacy-pool\n' bash "$SWEEP" imports hbtest-rg-01 --module module.x 2>&1)"
has  "an unrecognised child warns"       "unrecognised backend pool 'legacy-pool'" "$o"
hasnt "and no address is invented for it" "backendAddressPools/legacy-pool" "$o"
has  "--module overrides the address"    "module.x.azurerm_lb.main" "$o"

o="$(MOCK_LBS='hb-lb\n' MOCK_POOLS='' MOCK_PROBES='' MOCK_RULES='' bash "$SWEEP" imports hbtest-rg-01 2>&1)"
n="$(printf '%s\n' "$o" | grep -c '^terraform import')"
if [ "$n" -eq 2 ]; then
    printf '  ok   a half-built lb emits only what exists (%s commands)\n' "$n"; pass=$((pass+1))
else
    printf '  FAIL expected 2 import commands for a childless lb, got %s\n' "$n"; fail=$((fail+1))
fi

# --- imports: the resources beyond the load balancer -------------------------
# `imports` covers the whole tier module, not just the lb. These pin the parts
# where the ADDRESS is derived rather than fixed -- an index or a for_each key
# read off an Azure name. Get one of those wrong and the import silently adopts
# a resource under another one's address; nothing complains until a later apply
# proposes to change or destroy the wrong thing.

o="$(MOCK_VMS='hb-vm-1\nhb-vm-2\nhb-db-vm\n' bash "$SWEEP" imports hbtest-rg-01 2>&1)"
has  "app VMs are indexed in name order"  "azurerm_linux_virtual_machine.vm[0]' \\" "$o"
has  "and the second lands on [1]"        "azurerm_linux_virtual_machine.vm[1]' \\" "$o"
has  "the db VM has its own address"      "azurerm_linux_virtual_machine.db_vm[0]" "$o"
has  "and the index is flagged for review" "CHECK the order" "$o"

o="$(MOCK_NSGS='hb-vm-nsg\n' MOCK_NSG_RULES='allow-admin-0\nallow-admin-1\nallow-phish-0\nallow-lb-probe\n' \
     bash "$SWEEP" imports hbtest-rg-01 2>&1)"
has  "NSG rule for_each key comes off the name" 'azurerm_network_security_rule.vm_admin_in["1"]' "$o"
has  "the phish rule on a vm NSG is vm_phish_in" 'azurerm_network_security_rule.vm_phish_in["0"]' "$o"
hasnt "and not the lb one"                 'lb_phish_in' "$o"
has  "the probe rule is a count, not for_each" 'azurerm_network_security_rule.vm_probe_in[0]' "$o"
# The mock returns one rule list for every NSG, which is what surfaced this:
# an allow-https-* is only ever on the lb NSG, so seeing one elsewhere means
# the rule is not this module's and must not be adopted under its address.
hasnt "a 443 rule off the lb NSG is not adopted" 'lb_https_in' "$o"
o="$(MOCK_NSGS='hb-lb-nsg\n' MOCK_NSG_RULES='allow-https-0\n' bash "$SWEEP" imports hbtest-rg-01 2>&1)"
has  "and on the lb NSG it is"             'lb_https_in["0"]' "$o"

# A public IP the customer supplied via public_ip_id is NOT module-managed.
# Importing it would put a reserved address under Terraform's control and a
# later destroy would delete it -- and Azure has no undelete for a public IP.
o="$(MOCK_PIP_NAMES='customer-reserved-ip\n' bash "$SWEEP" imports hbtest-rg-01 2>&1)"
has  "a supplied public IP is refused"    "must not be imported" "$o"
hasnt "and no address is invented for it" "azurerm_public_ip" "$o"

o="$(MOCK_KV='hb-kv\n' MOCK_KV_SECRETS='hailbytes-db-password\nhailbytes-session-keys\nhailbytes-admin-initial-password\n' \
     MOCK_KV_SECRET_ID='https://hb-kv.vault.azure.net/secrets/s/abc123\n' \
     bash "$SWEEP" imports hbtest-rg-01 2>&1)"
has  "a secret imports by versioned URI"  "https://hb-kv.vault.azure.net/secrets/s/abc123" "$o"
has  "and maps to the right address"      "azurerm_key_vault_secret.session_keys" "$o"
has  "the generated values are recovered" "random_password.db" "$o"
has  "including both session keys"        "random_id.session_enc_key" "$o"
has  "and the plan caveat is stated"      "CHECK THE PLAN" "$o"
has  "values are substituted, not printed" '$(az keyvault secret show' "$o"

o="$(MOCK_KV_IDS='/subscriptions/S/resourceGroups/RG/providers/Microsoft.KeyVault/vaults/hb-kv\n' \
     MOCK_VMS='hb-vm-1\n' MOCK_VM_PRINCIPALS='p-vm-1\n' \
     MOCK_ROLE_ASSIGNMENTS='Key Vault Secrets User\tguid-1\tp-vm-1\n' \
     bash "$SWEEP" imports hbtest-rg-01 2>&1)"
has  "a VM-identity role assignment is placed" "azurerm_role_assignment.vm_kv_secrets_user[0]" "$o"
has  "under the roleAssignments id form"  "/providers/Microsoft.Authorization/roleAssignments/guid-1" "$o"

o="$(MOCK_KV_IDS='/subscriptions/S/resourceGroups/RG/providers/Microsoft.KeyVault/vaults/hb-kv\n' \
     MOCK_ROLE_ASSIGNMENTS='Key Vault Secrets User\tguid-9\tsomeone-else\n' \
     bash "$SWEEP" imports hbtest-rg-01 2>&1)"
has  "an unplaceable principal is flagged, not guessed" "is not a VM identity" "$o"

o="$(MOCK_VNETS='hb-vnet\n' MOCK_SUBNETS='hb-workload\n' \
     MOCK_SUBNET_NSG='/subscriptions/S/../nsg\n' bash "$SWEEP" imports hbtest-rg-01 2>&1)"
has  "a subnet association imports under the SUBNET id" \
     "azurerm_subnet_network_security_group_association.vm[0]' \\" "$o"

# --- regression: a loose mock pattern must not answer a specific call --------
# "monitor action-group list" CONTAINS "group list". When the mock answered it
# with the resource-GROUP names, `imports` emitted an action group import per
# resource group in the subscription -- four fabricated commands that named
# real-looking ids. The bug was in the mock, and it made the script look wrong.
o="$(MOCK_ACTION_GROUPS='' bash "$SWEEP" imports hbtest-rg-01 2>&1)"
hasnt "no action group is invented from the group list" "actionGroups/hbtest-rg-01" "$o"

# --- static: the tsv column-order rule --------------------------------------
# Cheap and durable: the behavioural assertions above pass for the wrong reason
# if the mock is ever reshaped to match a hash-form query, so pin the form too.
if grep -qE 'query "\[\]\.\{[a-z]+:' "$SWEEP"; then
    printf '  FAIL sweep-azure.sh uses a multiselect HASH tsv query (columns will be sorted)\n'
    fail=$((fail+1))
else
    printf '  ok   no multiselect HASH tsv query in sweep-azure.sh\n'; pass=$((pass+1))
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
