#!/usr/bin/env bash
#
# Unit tests for the pure logic in quickstart/deploy.sh.
#
# The wizard is interactive, so most of it can't be tested without a TTY and a
# Cloud Shell. These tests cover the parts that CAN go wrong silently and that
# a reader would never notice: cloud detection, the tier -> module-name mapping
# (a typo here sends a customer at a module that doesn't exist), and the fact
# that every billing-relevant branch actually emits a cost warning.
#
# Run: bash quickstart/tests/deploy_test.sh
#
# SC2034: variables set here (HAILBYTES_CLOUD, AZUREPS_HOST_ENVIRONMENT,
# PRODUCT, CLOUD, TIER, ...) are read by the functions sourced from deploy.sh,
# which shellcheck cannot follow across the `.` boundary.
# shellcheck disable=SC2034

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

# shellcheck source=/dev/null
HAILBYTES_WIZARD_LIB=1 . "${REPO}/quickstart/deploy.sh"

pass=0; fail=0
check() {  # check <description> <actual> <expected>
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"; pass=$((pass+1))
  else
    printf '  FAIL %s\n       expected %q\n       got      %q\n' "$1" "$3" "$2"; fail=$((fail+1))
  fi
}
check_contains() {  # check_contains <description> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then
    printf '  ok   %s\n' "$1"; pass=$((pass+1))
  else
    printf '  FAIL %s\n       %q not found in output\n' "$1" "$3"; fail=$((fail+1))
  fi
}

printf '\nCloud detection\n'
( HAILBYTES_CLOUD=azure; check "explicit override wins" "$(detect_cloud)" "azure" )
( HAILBYTES_CLOUD=aws;   check "explicit override wins (aws)" "$(detect_cloud)" "aws" )
(
  unset HAILBYTES_CLOUD AWS_EXECUTION_ENV AWS_REGION 2>/dev/null || true
  AZUREPS_HOST_ENVIRONMENT="cloud-shell/1.0"
  check "Azure Cloud Shell env var" "$(detect_cloud)" "azure"
)
(
  unset HAILBYTES_CLOUD AZUREPS_HOST_ENVIRONMENT ACC_CLOUD 2>/dev/null || true
  AWS_EXECUTION_ENV="CloudShell"
  check "AWS Cloud Shell env var" "$(detect_cloud)" "aws"
)

printf '\nModule path mapping — a typo here points customers at a nonexistent module\n'
for product in sat asm; do
  for cloud in aws azure; do
    for tier in single ha autoscale; do
      PRODUCT="$product" CLOUD="$cloud" TIER="$tier"
      got="$(module_path)"
      if [ -d "${REPO}/modules/${got}" ]; then
        printf '  ok   %s exists\n' "$got"; pass=$((pass+1))
      else
        printf '  FAIL %s does not exist in modules/\n' "$got"; fail=$((fail+1))
      fi
    done
  done
done

printf '\nMarketplace identifiers match the Terraform modules\n'
core_azure="${REPO}/modules/ha-hot-hot/azure/main.tf"
core_aws="${REPO}/modules/ha-hot-hot/aws/main.tf"
check_contains "Azure publisher matches the module" "$(cat "$core_azure")" "$AZURE_PUBLISHER"
for p in sat asm; do
  check_contains "Azure ${p} offer matches the module" "$(cat "$core_azure")" "${AZURE_OFFER[$p]}"
  check_contains "AWS ${p} product code matches the module" "$(cat "$core_aws")" "${AWS_PRODUCT_CODE[$p]}"
done

printf '\nPer-vCPU meter rate matches the cost documentation\n'
check_contains "meter rate appears in COST_SHAPES.md" "$(cat "${REPO}/COST_SHAPES.md")" "${METER_PER_VCPU_HOUR}/vCPU"

printf '\nCost warnings render and are visually unmissable\n'
out="$(NO_COLOR=1 cost_warning "Headline here" "detail one" "detail two")"
check_contains "warning carries the COST IMPACT banner" "$out" "COST IMPACT"
check_contains "warning includes the headline" "$out" "Headline here"
check_contains "warning includes each detail line" "$out" "detail two"

printf '\nEvery billing-relevant branch emits a cost warning\n'
src="$(cat "${REPO}/quickstart/deploy.sh")"
for fn in pick_tier pick_db_mode pick_scale_knobs pick_frontend; do
  body="$(awk "/^${fn}\\(\\) \\{/,/^\\}/" <<<"$src")"
  if [[ "$body" == *"cost_warning"* ]]; then
    printf '  ok   %s warns about cost\n' "$fn"; pass=$((pass+1))
  else
    printf '  FAIL %s changes the bill but emits no cost_warning\n' "$fn"; fail=$((fail+1))
  fi
done

printf '\nThe apply gate cannot be satisfied by a stray keypress\n'
apply_body="$(awk '/^run_plan_and_apply\(\) \{/,/^\}/' <<<"$src")"
check_contains "apply requires the literal word APPLY" "$apply_body" 'reply" != "APPLY"'
check_contains "a plan is always produced before apply" "$apply_body" "terraform plan"
check_contains "apply consumes the saved plan, not a fresh one" "$apply_body" "apply -input=false hailbytes.tfplan"

printf '\nExternal-DB password handling\n'
# NB: extract by next-function boundary, not by the first ^} — write_config
# contains a heredoc whose Terraform content has lines starting with "}".
wc_body="$(sed -n '/^write_config() {/,/^run_plan_and_apply() {/p' <<<"$src")"
check_contains "password file is chmod 600" "$wc_body" "chmod 600"
check_contains "password file is gitignored" "$wc_body" "gitignore"
# main.tf must never carry the password itself — only a pointer to the
# gitignored file. Assert on the main.tf heredoc specifically.
maintf_heredoc="$(sed -n "/cat > \"\${WORKDIR}\/main.tf\"/,/^EOF$/p" <<<"$src")"
if [[ "$maintf_heredoc" != *'EXT_DB_PASS'* ]]; then
  printf '  ok   password never interpolated into main.tf\n'; pass=$((pass+1))
else
  printf '  FAIL password is interpolated into main.tf\n'; fail=$((fail+1))
fi
check_contains "main.tf points at the secrets file instead" "$src" "comes from secrets.auto.tfvars"

printf '\nKey Vault naming avoids the 30-day purge-protection trap\n'
# The vault name is what bites a PoC operator: purge protection plus a 30-day
# soft-delete window means a same-named rebuild inside 30 days simply fails.
kv_body="$(sed -n '/^pick_key_vault_name() {/,/^warn_about_redis_retirement() {/p' <<<"$src")"
check_contains "the wizard explains why the name matters" "$kv_body" "purge protection"
check_contains "it offers a unique name for PoCs" "$kv_body" "KEY_VAULT_NAME="
check_contains "it warns that changing it later replaces the vault" "$kv_body" "REPLACES the vault"

# Only the tiers that create a Key Vault should ask, and only on Azure.
# NB: no subshells here — pass/fail counters incremented in a subshell are lost.
# ${VAR-unset} (no colon) so a variable deliberately set to "" reads as "",
# which is the state "asked, declined, use the module's derived name".
CLOUD=aws TIER=ha PRODUCT=sat
pick_key_vault_name >/dev/null 2>&1
check "AWS is never asked about a Key Vault" "${KEY_VAULT_NAME-unset}" ""

CLOUD=azure TIER=single PRODUCT=sat
pick_key_vault_name >/dev/null 2>&1
check "single-vm has no Key Vault to name" "${KEY_VAULT_NAME-unset}" ""

# Declining the PoC prompt must leave the module's derived name alone.
CLOUD=azure TIER=ha PRODUCT=sat
pick_key_vault_name >/dev/null 2>&1 </dev/null
check "declining leaves the derived name in place" "${KEY_VAULT_NAME-unset}" ""

# Accepting produces a name Azure will accept: <=24 chars, starts with a letter,
# alphanumeric only. A name Azure rejects fails at apply, not at plan.
CLOUD=azure TIER=ha PRODUCT=sat
pick_key_vault_name >/dev/null 2>&1 <<<"y"
if [[ "${KEY_VAULT_NAME}" =~ ^[a-zA-Z][a-zA-Z0-9]{2,23}$ ]]; then
  printf '  ok   generated vault name is valid for Azure (%s)\n' "$KEY_VAULT_NAME"; pass=$((pass+1))
else
  printf '  FAIL generated vault name %q is not a valid Azure Key Vault name\n' "${KEY_VAULT_NAME:-}"; fail=$((fail+1))
fi
# It must also satisfy the module's own validation regex, which additionally
# caps at 24 and allows hyphens; a name the wizard emits that the module rejects
# would fail at plan with a confusing error.
if [ "${#KEY_VAULT_NAME}" -le 24 ]; then
  printf '  ok   generated name is within the 24-char Key Vault limit\n'; pass=$((pass+1))
else
  printf '  FAIL generated name is %d chars, over the 24-char limit\n' "${#KEY_VAULT_NAME}"; fail=$((fail+1))
fi

printf '\nThe retiring cache is disclosed before it is deployed\n'
redis_body="$(sed -n '/^warn_about_redis_retirement() {/,/^# ---/p' <<<"$src")"
check_contains "retirement is stated" "$redis_body" "being retired"
check_contains "the Basic/Standard/Premium date is given" "$redis_body" "2028-09-30"
check_contains "the Enterprise date is given" "$redis_body" "2027-03-31"
# The costly mistake this prevents: buying Premium for zone redundancy on a
# service whose successor includes it for less.
check_contains "it steers away from the Premium upsell" "$redis_body" "NOT buy the"

printf '\nBoth new steps are actually wired into the wizard flow\n'
main_body="$(sed -n '/^main() {/,/^}/p' <<<"$src")"
check_contains "pick_key_vault_name runs" "$main_body" "pick_key_vault_name"
check_contains "warn_about_redis_retirement runs" "$main_body" "warn_about_redis_retirement"
check_contains "key_vault_name reaches the generated config" "$src" "key_vault_name = "

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
