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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
