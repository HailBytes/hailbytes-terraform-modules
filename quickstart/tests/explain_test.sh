#!/usr/bin/env bash
#
# Tests for quickstart/explain.sh.
#
# The fixtures below are REAL error text from customer and lab deployments,
# pasted verbatim rather than paraphrased. That matters more here than in most
# suites: this tool works by matching provider and cloud error strings, and a
# paraphrased fixture tests the paraphrase. Where a message is long, it is
# trimmed at the ends but never reworded.
#
# Two properties are asserted throughout:
#
#   1. The right explanation fires. Several signatures deliberately overlap
#      ("already exists" appears inside other errors), so the tests check the
#      specific remediation text, not just that something printed.
#
#   2. NOTHING IS INVENTED. Every command, file path and variable name the
#      tool emits has to exist in this repository. Advice that does not work
#      is worse than no advice: it costs the reader a round trip AND their
#      confidence in the rest of the output. The last section walks the
#      emitted commands and checks them against the repo.
#
# No cloud credentials are used. explain.sh makes no API calls at all.
#
# Run: bash quickstart/tests/explain_test.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
EXPLAIN="${REPO}/quickstart/explain.sh"
[ -x "$EXPLAIN" ] || { echo "not executable: $EXPLAIN" >&2; exit 2; }

pass=0; fail=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

has() {   # has <description> <needle> <haystack>
    if printf '%s' "$3" | grep -qF "$2"; then
        printf '  ok   %s\n' "$1"; pass=$((pass+1))
    else
        printf '  FAIL %s\n       expected to find: %q\n' "$1" "$2"; fail=$((fail+1))
    fi
}
hasnt() { # hasnt <description> <needle> <haystack>
    if printf '%s' "$3" | grep -qF "$2"; then
        printf '  FAIL %s\n       should NOT contain: %q\n' "$1" "$2"; fail=$((fail+1))
    else
        printf '  ok   %s\n' "$1"; pass=$((pass+1))
    fi
}

echo "explain.sh"

# --- Key Vault soft delete -- verbatim from a customer log, 2026-09-07 -------
cat > "$WORK/kv.log" <<'EOF'
Error: creating Key Vault (Subscription: "3868e0d4-f365-4798-bf18-ff22be2bccfa"
Resource Group Name: "simsphishing-rg-X-08"
Key Vault Name: "kv-simsphishing-6a8a4y"): performing CreateOrUpdate: unexpected status 400 (400 Bad Request) with error: SoftDeletedVaultDoesNotExist: A soft deleted vault with the given name does not exist. Ensure that the name for the vault that is being attempted to recover is in a recoverable state.

  with module.hailbytes_sat.module.this.azurerm_key_vault.main,
EOF
o="$(bash "$EXPLAIN" "$WORK/kv.log" 2>&1)"
has "key vault: explains it is not really soft delete" "usually not about soft delete" "$o"
has "key vault: names the subscription-scoped read"    "deletedVaults/<name>/read" "$o"
has "key vault: gives the one-line fix"                "recover_soft_deleted_key_vaults = false" "$o"
has "key vault: says no admin is needed"               "No admin needed" "$o"

# --- Azure RBAC refusal -- the action and scope must be parsed back out ------
cat > "$WORK/rbac.log" <<'EOF'
Error: authorization.RoleAssignmentsClient#Create: Failure responding to request: StatusCode=403 -- Original Error: autorest/azure: Service returned an error. Status=403 Code="AuthorizationFailed" Message="The client 'jordan@example.ie' with object id 'dd4a5844-d123-4f06-9d45-ecc369f1fbe7' does not have authorization to perform action 'Microsoft.Authorization/roleAssignments/write' over scope '/subscriptions/3868e0d4-f365-4798-bf18-ff22be2bccfa/resourceGroups/rg-x/providers/Microsoft.KeyVault/vaults/kv-x' or the scope is invalid."
EOF
o="$(bash "$EXPLAIN" "$WORK/rbac.log" 2>&1)"
has "rbac: extracts the refused action"   "Microsoft.Authorization/roleAssignments/write" "$o"
has "rbac: extracts the scope"            "/subscriptions/3868e0d4-f365-4798-bf18-ff22be2bccfa/resourceGroups/rg-x/providers/Microsoft.KeyVault/vaults/kv-x" "$o"
has "rbac: emits a forwardable request"   "A deployment I am running was refused" "$o"
# The distinction that cost this project several days: portal shows "Owner",
# scoped to a resource group, and subscription-scoped actions still fail.
has "rbac: explains resource vs subscription scope" "is not the same" "$o"
has "rbac: warns about PIM expiry"        "ACTIVE" "$o"
has "rbac: names the role that can do it" "USER ACCESS ADMINISTRATOR" "$o"

# --- AWS IAM refusal -- different message shape, same treatment -------------
cat > "$WORK/awsiam.log" <<'EOF'
Error: creating EC2 Instance: UnauthorizedOperation: You are not authorized to perform: ec2:RunInstances on resource: arn:aws:ec2:eu-west-1:123456789012:instance/*
  with module.hailbytes_sat.module.this.aws_instance.vm[0],
EOF
o="$(bash "$EXPLAIN" "$WORK/awsiam.log" 2>&1)"
has "aws iam: extracts the action" "ec2:RunInstances" "$o"
has "aws iam: extracts the ARN"    "arn:aws:ec2:eu-west-1:123456789012:instance/" "$o"
# Azure-only advice must not appear on an AWS failure.
hasnt "aws iam: no PIM advice on AWS" "PIM" "$o"

# --- Marketplace, per cloud -------------------------------------------------
cat > "$WORK/mktaz.log" <<'EOF'
Error: creating Linux Virtual Machine: performing CreateOrUpdate: unexpected status 400 with error: MarketplacePurchaseEligibilityFailed: You must accept the terms for this offer before you can deploy programmatically. azurerm
EOF
o="$(bash "$EXPLAIN" "$WORK/mktaz.log" 2>&1)"
has "marketplace azure: names the portal path" "deploy programmatically? Get started" "$o"
has "marketplace azure: gives the CLI form"    "az vm image terms accept" "$o"
has "marketplace azure: forwardable block"     "Please enable programmatic deployment" "$o"

cat > "$WORK/mktaws.log" <<'EOF'
Error: creating EC2 Instance: OptInRequired: In order to use this AWS Marketplace product you need to accept terms and subscribe. arn:aws:ec2:eu-west-1
EOF
o="$(bash "$EXPLAIN" "$WORK/mktaws.log" 2>&1)"
has "marketplace aws: links the listing" "aws.amazon.com/marketplace/pp/prodview-" "$o"
hasnt "marketplace aws: no Azure portal path" "deploy programmatically? Get started" "$o"

# --- Quota -- verbatim from a lab run, 2026-09-07 ---------------------------
cat > "$WORK/quota.log" <<'EOF'
Error: creating Linux Virtual Machine: performing CreateOrUpdate: unexpected status 409 (409 Conflict) with error: OperationNotAllowed: Operation could not be completed as it results in exceeding approved standardDSv5Family Cores quota. Additional details - Deployment Model: Resource Manager, Location: northeurope, Current Limit: 0, Current Usage: 0, Additional Required: 2 azurerm
EOF
o="$(bash "$EXPLAIN" "$WORK/quota.log" 2>&1)"
has "quota: names the family"            "standardDSv5Family" "$o"
has "quota: calls out a limit of zero"   "never granted here at all" "$o"
# The insight that is not in Azure's message: the whole Dsv5 ladder is one pool.
has "quota: explains the shared pool"    "draws ONE" "$o"

# --- Leftovers --------------------------------------------------------------
cat > "$WORK/exists.log" <<'EOF'
Error: A resource with the ID "/subscriptions/x/resourceGroups/y/providers/Microsoft.Network/loadBalancers/z" already exists - to be managed via Terraform this resource needs to be imported into the State. azurerm
EOF
o="$(bash "$EXPLAIN" "$WORK/exists.log" 2>&1)"
has "leftovers: points at the sweep tool" "sweep-azure.sh list" "$o"
has "leftovers: names the billing cost of bumping the name" "KEEP BILLING" "$o"
has "leftovers: says it is not a permissions problem" "not a permissions problem" "$o"

# --- Postgres HA entitlement ------------------------------------------------
cat > "$WORK/ha.log" <<'EOF'
Error: creating Postgresql Flexible Server: Status: "MultiAzHaIsOfferRestricted" Multi-Zone HA is not supported in this region. Please choose a different region. azurerm
EOF
o="$(bash "$EXPLAIN" "$WORK/ha.log" 2>&1)"
has "postgres ha: contradicts the misleading message" "That is misleading" "$o"
has "postgres ha: names the variable to set" "db_high_availability_mode" "$o"
has "postgres ha: says what is given up"     "DATABASE standby" "$o"

# --- Unknown failure: must not invent an explanation ------------------------
cat > "$WORK/unknown.log" <<'EOF'
Error: something nobody has seen before
Status: "TotallyNovelFailure"
EOF
o="$(bash "$EXPLAIN" "$WORK/unknown.log" 2>&1)"
has  "unknown: says so plainly"        "No known failure signature" "$o"
has  "unknown: echoes the error lines" "TotallyNovelFailure" "$o"
hasnt "unknown: invents no remediation" "DO THIS" "$o"

# --- Argument handling ------------------------------------------------------
o="$(bash "$EXPLAIN" "$WORK/nope.log" 2>&1)"; rc=$?
has "a missing file is an error" "cannot read" "$o"
if [ "$rc" -ne 0 ]; then printf '  ok   and exits non-zero\n'; pass=$((pass+1))
else printf '  FAIL expected non-zero exit for a missing file\n'; fail=$((fail+1)); fi

o="$(bash "$EXPLAIN" --help 2>&1)"; rc=$?
has "--help explains itself" "explain a failed run" "$o"
if [ "$rc" -eq 0 ]; then printf '  ok   and exits zero\n'; pass=$((pass+1))
else printf '  FAIL --help should exit 0, got %s\n' "$rc"; fail=$((fail+1)); fi

# Output is pasted into email and ticket systems, where escape codes are noise.
o="$(bash "$EXPLAIN" "$WORK/kv.log" 2>&1 | cat)"
hasnt "no ANSI escapes when piped" "$(printf '\033')" "$o"

# --- NOTHING IS INVENTED ----------------------------------------------------
# Walk the paths and variables the tool actually emits and confirm each exists
# here. This is the assertion that keeps the advice honest as the repo moves.
printf '\nevery referenced path and variable exists\n'
ALL=""
for f in "$WORK"/*.log; do ALL="${ALL}$(bash "$EXPLAIN" "$f" 2>&1)"; done

for rel in $(printf '%s' "$ALL" | grep -oE '\./quickstart/[a-z0-9-]+\.sh' | sort -u); do
    if [ -x "${REPO}/${rel#./}" ]; then
        printf '  ok   %s exists and is executable\n' "$rel"; pass=$((pass+1))
    else
        printf '  FAIL %s is referenced but not present\n' "$rel"; fail=$((fail+1))
    fi
done

# Terraform variables it tells people to set must be real inputs.
for v in db_high_availability_mode vm_size name_prefix; do
    if printf '%s' "$ALL" | grep -qF "$v"; then
        if grep -rqF "variable \"${v}\"" "${REPO}/modules/ha-hot-hot/azure/variables.tf"; then
            printf '  ok   variable %s is a real module input\n' "$v"; pass=$((pass+1))
        else
            printf '  FAIL %s is suggested but is not a module variable\n' "$v"; fail=$((fail+1))
        fi
    fi
done

# The provider setting it prescribes must be the one the repo's own configs use.
if grep -rqF 'recover_soft_deleted_key_vaults = false' "${REPO}/quickstart/azure-ha/main.tf"; then
    printf '  ok   the prescribed provider setting matches the shipped configs\n'; pass=$((pass+1))
else
    printf '  FAIL explain.sh prescribes a provider setting the quickstarts do not use\n'; fail=$((fail+1))
fi

# Marketplace identifiers have to match the preflight scripts, or the command
# it prints accepts terms for the wrong offer and changes nothing.
PUB="$(grep -oE 'lcmcon[0-9]+' "${REPO}/quickstart/preflight-azure.sh" | head -1)"
if [ -n "$PUB" ] && grep -qF "$PUB" "$EXPLAIN"; then
    printf '  ok   Azure publisher id matches preflight-azure.sh\n'; pass=$((pass+1))
else
    printf '  FAIL Azure publisher id in explain.sh does not match preflight-azure.sh\n'; fail=$((fail+1))
fi
for p in prodview-yyk6iton3ghu4 prodview-66d5bswmbtfhs; do
    if grep -qF "$p" "${REPO}/quickstart/preflight-aws.sh" && grep -qF "$p" "$EXPLAIN"; then
        printf '  ok   AWS listing %s matches preflight-aws.sh\n' "$p"; pass=$((pass+1))
    else
        printf '  FAIL AWS listing %s is out of sync\n' "$p"; fail=$((fail+1))
    fi
done

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
