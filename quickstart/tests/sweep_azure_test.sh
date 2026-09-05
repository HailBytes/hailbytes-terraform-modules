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
        *"storage account list"*)       printf '%b' "${MOCK_STORAGE-}" ;;
        *"network lb list"*)            printf '%b' "${MOCK_LBS-}" ;;
        *"network lb address-pool list"*) printf '%b' "${MOCK_POOLS-}" ;;
        *"network lb probe list"*)      printf '%b' "${MOCK_PROBES-}" ;;
        *"network lb rule list"*)       printf '%b' "${MOCK_RULES-}" ;;
        *"diagnostic-settings list"*)   printf '%b' "${MOCK_DIAG-}" ;;
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

# The one BLOCKING guard: a live hostname resolving into the group. localhost
# is used because it resolves identically everywhere, including in CI.
o="$(MOCK_RG_COUNT=3 MOCK_PIPS='127.0.0.1\thb-lb-pip\tNone\n' \
     bash "$SWEEP" delete hbtest-rg-01 --hostname localhost 2>&1)"
has  "a live hostname in the group blocks the delete" "Refusing to delete" "$o"
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
