#!/usr/bin/env bash
# HailBytes — live Azure drill for the state backend and the lost-state recovery.
#
# The other suites in this directory run against a mocked `az` and never touch
# a cloud. They prove the scripts emit the right strings. They cannot prove
# Azure ACCEPTS those strings -- an import id form the provider rejects, an RBAC
# grant that does not propagate, a backend the CLI cannot authenticate to. This
# script is the part that needs a real subscription.
#
#   ./quickstart/tests/azure_live_drill.sh backend    ~5 min,  ~$0
#   ./quickstart/tests/azure_live_drill.sh recovery    ~45 min, a few dollars
#   ./quickstart/tests/azure_live_drill.sh cleanup     remove what drills left
#
# Options:
#   --location LOC     HB_LOCATION        default northeurope
#   --subscription ID  HB_SUBSCRIPTION_ID default: current az context
#   --keep                                do not destroy at the end (inspect it)
#   --yes                                 skip the confirmation prompt
#
# WHAT EACH DRILL PROVES
#
# backend   bootstrap-state-azure.sh produces a backend Terraform can actually
#           use, and state written through it survives the working directory
#           being deleted. That last step is the incident, reproduced: the
#           directory goes, and `terraform init` from backend.tf alone has to
#           come back with a plan showing NO CHANGES.
#
#           Needs: a subscription. No marketplace subscription, no VMs, no
#           meaningful spend -- it deploys one empty resource group.
#
# recovery  The whole runbook end to end against a real HA deployment: deploy,
#           destroy the state, rebuild it from `sweep-azure.sh imports`, and
#           require `terraform plan` to come back clean. This is the one that
#           exercises every import id form against the real provider.
#
#           Needs: an active HailBytes SAT Marketplace subscription, and it
#           bills the per-vCPU meter for as long as it runs.
#
# SAFETY
# Every resource a drill creates is named with the drill prefix and a UTC
# timestamp, and nothing is deleted unless its name carries that prefix. The
# recovery drill runs generated import commands unreviewed, which is exactly
# what you must never do in production -- it is safe here only because the
# resource group is one this script created minutes earlier.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BOOTSTRAP="${REPO}/quickstart/bootstrap-state-azure.sh"
SWEEP="${REPO}/quickstart/sweep-azure.sh"

PREFIX="hbdrill"
LOCATION="${HB_LOCATION:-northeurope}"
SUB="${HB_SUBSCRIPTION_ID:-}"
KEEP=0
ASSUME_YES=0
MODE="${1:-}"
[ -n "$MODE" ] && shift

while [ $# -gt 0 ]; do
    case "$1" in
        --location)       LOCATION="$2"; shift ;;
        --location=*)     LOCATION="${1#--location=}" ;;
        --subscription)   SUB="$2"; shift ;;
        --subscription=*) SUB="${1#--subscription=}" ;;
        --keep)           KEEP=1 ;;
        --yes)            ASSUME_YES=1 ;;
        -h|--help)        sed -n '/^#   \.\/quickstart\/tests\/azure_live_drill/,/^#   --yes/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

B=$'\033[1m'; R=$'\033[0m'; GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; DIM=$'\033[2m'
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$R"; }
ok()   { printf '  %s✓%s %s\n' "$GRN" "$R" "$*"; PASS=$((PASS+1)); }
bad()  { printf '  %s✗%s %s\n' "$RED" "$R" "$*"; FAIL=$((FAIL+1)); }
note() { printf '    %s%s%s\n' "$DIM" "$*" "$R"; }
warn() { printf '  %s!%s %s\n' "$YLW" "$R" "$*"; }
die()  { printf '%sERROR: %s%s\n' "$RED" "$*" "$R" >&2; exit 1; }

PASS=0; FAIL=0
TS="$(date -u +%m%d%H%M)"
WORK=""

az_() { if [ -n "$SUB" ]; then az "$@" --subscription "$SUB"; else az "$@"; fi; }

# Never delete something a drill did not make. Checked immediately before every
# destructive call, not once at the top: the guard is worthless if the name it
# guards can be reassigned between the check and the delete.
guard_drill_rg() {
    case "$1" in
        ${PREFIX}-*) : ;;
        *) die "refusing to touch '${1}': not a ${PREFIX}-* resource group." ;;
    esac
}

preflight() {
    command -v az        >/dev/null || die "az CLI not found."
    command -v terraform >/dev/null || die "terraform not found."
    [ -x "$BOOTSTRAP" ] || die "not executable: ${BOOTSTRAP}"
    [ -x "$SWEEP" ]     || die "not executable: ${SWEEP}"

    local name
    name="$(az account show ${SUB:+--subscription "$SUB"} --query name -o tsv 2>&1)" \
        || die "cannot read the Azure subscription. Run 'az login'."$'\n'"${name}"
    [ -n "$SUB" ] || SUB="$(az account show --query id -o tsv)"
    note "subscription  ${name}"
    note "location      ${LOCATION}"

    if [ "$ASSUME_YES" -ne 1 ]; then
        printf '\nThis creates real Azure resources and bills for them. Type DRILL to continue: '
        local reply; read -r reply || true
        [ "$reply" = DRILL ] || { echo "Nothing created."; exit 0; }
    fi
}

# --------------------------------------------------------------------------
# Drill 1: the state backend
# --------------------------------------------------------------------------
drill_backend() {
    local state_rg="${PREFIX}-state-${TS}"
    local target_rg="${PREFIX}-backend-${TS}"
    WORK="$(mktemp -d -t hbdrill.XXXXXX)"

    step "Creating the state backend"
    "$BOOTSTRAP" --out "$WORK" --resource-group "$state_rg" \
        --location "$LOCATION" --key "drill-${TS}.tfstate" \
        ${SUB:+--subscription "$SUB"} \
        || die "bootstrap-state-azure.sh failed."

    [ -f "${WORK}/backend.tf" ] && ok "backend.tf written" || bad "no backend.tf"
    grep -q 'use_azuread_auth = true' "${WORK}/backend.tf" \
        && ok "backend uses Entra auth" || bad "backend.tf is missing use_azuread_auth"

    local acct
    acct="$(grep storage_account_name "${WORK}/backend.tf" | sed 's/.*"\(.*\)".*/\1/')"
    note "state account ${acct}"

    # Shared keys must be OFF. If they are on, the backend would silently work
    # through a credential we deliberately disabled, and the Entra path -- the
    # thing under test -- would never be exercised.
    if [ "$(az_ storage account show -n "$acct" -g "$state_rg" --query allowSharedKeyAccess -o tsv)" = "false" ]; then
        ok "shared key access is disabled"
    else
        bad "shared key access is ENABLED -- the Entra path is not being tested"
    fi
    [ "$(az_ storage account blob-service-properties show --account-name "$acct" \
         --resource-group "$state_rg" --query isVersioningEnabled -o tsv)" = "true" ] \
        && ok "blob versioning is on" || bad "blob versioning is off"
    [ -n "$(az_ lock list -g "$state_rg" --query "[?name=='protect-tfstate'].name" -o tsv)" ] \
        && ok "state group carries a delete lock" || bad "no delete lock on the state group"

    step "Applying a trivial root module through the backend"
    cat > "${WORK}/main.tf" <<EOF
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = ">= 4.0, < 5.0" }
  }
}
provider "azurerm" {
  resource_provider_registrations = "none"
  features {}
}
resource "azurerm_resource_group" "drill" {
  name     = "${target_rg}"
  location = "${LOCATION}"
  tags     = { purpose = "hailbytes-state-drill", created = "${TS}" }
}
EOF
    ( cd "$WORK" && terraform init -input=false >/dev/null 2>&1 ) \
        && ok "terraform init accepted the backend" \
        || { bad "terraform init failed against the backend"; ( cd "$WORK" && terraform init -input=false 2>&1 | tail -20 ); return; }

    ( cd "$WORK" && terraform apply -input=false -auto-approve >/dev/null 2>&1 ) \
        && ok "apply succeeded" || { bad "apply failed"; return; }

    # The whole point: state must NOT be on disk.
    if [ -f "${WORK}/terraform.tfstate" ] && [ -s "${WORK}/terraform.tfstate" ]; then
        bad "a local terraform.tfstate exists -- state did not go to the backend"
    else
        ok "no local state file (it went to the blob)"
    fi
    [ -n "$(az_ storage blob list --account-name "$acct" -c tfstate --auth-mode login \
            --query "[?name=='drill-${TS}.tfstate'].name" -o tsv 2>/dev/null)" ] \
        && ok "state blob exists in the container" || bad "no state blob in the container"

    # --- The incident, reproduced -----------------------------------------
    step "Simulating the session loss"
    local survivor; survivor="$(mktemp -d -t hbdrill2.XXXXXX)"
    cp "${WORK}/backend.tf" "${WORK}/main.tf" "$survivor/"
    rm -rf "$WORK"
    WORK="$survivor"
    note "working directory deleted; only backend.tf and main.tf carried over"
    note "this is what a committed repo checkout looks like after Cloud Shell ends"

    ( cd "$WORK" && terraform init -input=false >/dev/null 2>&1 ) \
        && ok "init from backend.tf alone succeeded" || { bad "init failed after the loss"; return; }

    # -detailed-exitcode: 0 = no changes, 2 = changes. A plan proposing to
    # CREATE the resource group is the failure this whole change exists to
    # prevent, and it exits 2.
    ( cd "$WORK" && terraform plan -input=false -detailed-exitcode >/dev/null 2>&1 )
    case $? in
        0) ok "plan reports NO CHANGES -- the state survived the session" ;;
        2) bad "plan proposes changes -- state did NOT survive"
           ( cd "$WORK" && terraform plan -input=false 2>&1 | grep -E '^\s+[#+-]' | head -10 ) ;;
        *) bad "plan errored" ;;
    esac

    if [ "$KEEP" -eq 1 ]; then
        warn "--keep set; leaving ${target_rg} and ${state_rg} in place"
        note "working directory: ${WORK}"
        return
    fi

    step "Tearing down"
    ( cd "$WORK" && terraform destroy -input=false -auto-approve >/dev/null 2>&1 ) \
        && ok "target resource group destroyed" || warn "destroy failed -- clean up ${target_rg} by hand"
    guard_drill_rg "$state_rg"
    az_ lock delete --name protect-tfstate -g "$state_rg" -o none 2>/dev/null
    az_ group delete -n "$state_rg" --yes --no-wait -o none 2>/dev/null \
        && ok "state group deletion started" || warn "could not delete ${state_rg}"
    rm -rf "$WORK"
}

# --------------------------------------------------------------------------
# Drill 2: the lost-state recovery
# --------------------------------------------------------------------------
drill_recovery() {
    local rg="${PREFIX}-recovery-${TS}"
    # The quickstart takes no key_vault_name; it derives every name from
    # `environment`, so that is the knob that makes a drill run unique.
    # It has to be: the vault is created with purge protection and a 30-day
    # soft-delete window, so a second drill reusing a name inside 30 days
    # simply fails, and cannot be forced.
    local env="d${TS}"
    local prefix="hailbytes-sat-${env}"
    WORK="$(mktemp -d -t hbdrill.XXXXXX)"

    step "Deploying the azure-ha quickstart into ${rg}"
    note "this takes 30-45 minutes; Postgres Flexible Server is the long pole"
    warn "the per-vCPU Marketplace meter bills for as long as this runs"

    local my_ip; my_ip="$(curl -4 -fsS -m 5 ifconfig.me 2>/dev/null || echo 10.0.0.0)"
    cp "${REPO}/quickstart/azure-ha/main.tf" "${WORK}/main.tf"
    local ssh_key
    ssh_key="$(cat "${HOME}/.ssh/id_ed25519.pub" 2>/dev/null || cat "${HOME}/.ssh/id_rsa.pub" 2>/dev/null)"
    [ -n "$ssh_key" ] || die "no SSH public key in ~/.ssh. Generate one: ssh-keygen -t ed25519"
    cat > "${WORK}/terraform.tfvars" <<EOF
resource_group_name = "${rg}"
location            = "${LOCATION}"
environment         = "${env}"
allowed_cidrs       = ["${my_ip}/32"]
ssh_public_key      = "${ssh_key}"
EOF
    note "name prefix   ${prefix}"

    ( cd "$WORK" && terraform init -input=false >/dev/null && \
      terraform apply -input=false -auto-approve ) \
        || { bad "deployment failed -- nothing to recover"; return; }
    ok "deployment applied"

    # The baseline. Every address in state now is one the recovery must
    # reproduce; anything missing afterwards is a gap in the import coverage.
    ( cd "$WORK" && terraform state list | sort ) > "${WORK}/before.txt"
    local n_before; n_before="$(wc -l < "${WORK}/before.txt")"
    ok "baseline captured: ${n_before} resources in state"

    step "Destroying the state (the incident)"
    local recovered; recovered="$(mktemp -d -t hbdrillrec.XXXXXX)"
    cp "${WORK}/main.tf" "${WORK}/terraform.tfvars" "$recovered/"
    note "config carried over; state and .terraform deliberately left behind"

    step "Generating import commands"
    "$SWEEP" imports "$rg" ${SUB:+--subscription "$SUB"} \
        --module module.hailbytes_sat.module.this > "${recovered}/imports.txt" 2>"${recovered}/imports.err"
    local n_cmds; n_cmds="$(grep -c '^terraform import' "${recovered}/imports.txt")"
    ok "emitted ${n_cmds} import commands"
    if [ -s "${recovered}/imports.err" ]; then
        warn "the emitter warned about:"
        sed 's/^/      /' "${recovered}/imports.err" | head -20
    fi

    step "Running them"
    warn "generated commands are being run UNREVIEWED -- only safe because this"
    warn "resource group was created by this script a few minutes ago"
    ( cd "$recovered" && terraform init -input=false >/dev/null 2>&1 )

    # Each command spans three lines (command, address, id). Reassemble and run
    # one at a time so a failure names the resource it failed on.
    local failed=0 ran=0
    while IFS= read -r cmd; do
        ran=$((ran+1))
        if ! ( cd "$recovered" && eval "$cmd" >/dev/null 2>>"${recovered}/import.err" ); then
            failed=$((failed+1))
            printf '      %sfailed:%s %s\n' "$RED" "$R" "$(sed 's/terraform import *//' <<<"$cmd" | cut -c1-90)"
        fi
    done < <(awk '/^terraform import/{c=$0; getline a; getline b; gsub(/\\$/,"",c); gsub(/\\$/,"",a); print c" "a" "b}' "${recovered}/imports.txt" | sed 's/  */ /g')

    if [ "$failed" -eq 0 ]; then
        ok "all ${ran} imports accepted by the provider"
    else
        bad "${failed} of ${ran} imports were rejected"
        note "reasons in ${recovered}/import.err"
    fi

    step "The verdict: is the plan clean?"
    ( cd "$recovered" && terraform plan -input=false -detailed-exitcode >/dev/null 2>&1 )
    case $? in
        0) ok "terraform plan reports NO CHANGES -- the recovery is complete" ;;
        2) bad "plan proposes changes; the recovery is incomplete"
           note "what it still wants to do:"
           ( cd "$recovered" && terraform plan -input=false -no-color 2>&1 \
             | grep -E '^  # ' | head -25 | sed 's/^/      /' ) ;;
        *) bad "plan errored"; ( cd "$recovered" && terraform plan -input=false 2>&1 | tail -15 ) ;;
    esac

    ( cd "$recovered" && terraform state list | sort ) > "${recovered}/after.txt"
    local missing; missing="$(comm -23 "${WORK}/before.txt" "${recovered}/after.txt")"
    if [ -z "$missing" ]; then
        ok "every resource from the baseline is back in state"
    else
        bad "$(wc -l <<<"$missing") resources are missing from the recovered state:"
        sed 's/^/      /' <<<"$missing" | head -25
        note "each of these is a gap in sweep-azure.sh imports"
    fi

    if [ "$KEEP" -eq 1 ]; then
        warn "--keep set; ${rg} is still running and still billing"
        note "recovered workspace: ${recovered}"
        note "destroy with: cd ${recovered} && terraform destroy"
        return
    fi

    step "Tearing down"
    guard_drill_rg "$rg"
    ( cd "$recovered" && terraform destroy -input=false -auto-approve >/dev/null 2>&1 ) \
        && ok "destroyed via the recovered state (which also proves it is usable)" \
        || { warn "destroy from recovered state failed; falling back to the group delete"
             az_ lock delete --name "${prefix}-pg-no-delete" -g "$rg" \
                --resource-name "${prefix}-pg" \
                --resource-type Microsoft.DBforPostgreSQL/flexibleServers \
                --namespace Microsoft.DBforPostgreSQL -o none 2>/dev/null
             az_ group delete -n "$rg" --yes --no-wait -o none 2>/dev/null; }
    warn "The Key Vault is soft-deleted with purge protection and holds its name"
    warn "for 30 days. The next drill gets a new timestamp, so it will not collide."
    rm -rf "$WORK" "$recovered"
}

# --------------------------------------------------------------------------
cmd_cleanup() {
    step "Resource groups left by previous drills"
    local groups; groups="$(az_ group list --query "[?starts_with(name, '${PREFIX}-')].name" -o tsv)"
    [ -n "$groups" ] || { ok "nothing to clean up"; return; }
    printf '%s\n' "$groups" | sed 's/^/    /'
    if [ "$ASSUME_YES" -ne 1 ]; then
        printf '\nDelete all of these? Type DELETE: '
        local reply; read -r reply || true
        [ "$reply" = DELETE ] || { echo "Nothing deleted."; return; }
    fi
    local g
    while IFS= read -r g; do
        [ -n "$g" ] || continue
        guard_drill_rg "$g"
        az_ lock list -g "$g" --query "[].id" -o tsv 2>/dev/null | while IFS= read -r l; do
            [ -n "$l" ] && az_ lock delete --ids "$l" -o none 2>/dev/null
        done
        az_ group delete -n "$g" --yes --no-wait -o none 2>/dev/null \
            && ok "deletion started: ${g}" || warn "could not delete ${g}"
    done <<<"$groups"
}

case "$MODE" in
    backend)  preflight; drill_backend ;;
    recovery) preflight; drill_recovery ;;
    all)      preflight; drill_backend; drill_recovery ;;
    cleanup)  preflight; cmd_cleanup ;;
    ""|help|-h|--help)
        sed -n '/^#   \.\/quickstart\/tests\/azure_live_drill/,/^#   --yes/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 0 ;;
    *) echo "unknown drill: ${MODE}" >&2; exit 2 ;;
esac

printf '\n%s%d passed, %d failed%s\n' "$B" "$PASS" "$FAIL" "$R"
[ "$FAIL" -eq 0 ]
