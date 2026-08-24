#!/usr/bin/env bash
#
# Unit + mocked-CLI tests for the cloud-account-prerequisites logic:
#   - quickstart/deploy.sh's azure_providers_for_tier / aws_service_linked_roles_for_tier
#     / check_cloud_prerequisites (sourced as a library, like deploy_test.sh does)
#   - quickstart/preflight-aws.sh, run as a real subprocess against mocked
#     `az` / `aws` so its actual output and exit codes are exercised, not
#     just its source text
#   - the standalone preflight-azure.sh / preflight-aws.sh provider and
#     service-linked-role lists staying byte-for-byte in sync with
#     deploy.sh's copies. This is the class of bug that let
#     docs/DEPLOY_FROM_GALLERY.md drift out of date with the real provider
#     list (hailbytes-sat#912 added Microsoft.Cache; that doc did not, until
#     it was caught by inspection rather than by a test) -- these assertions
#     are how that stops being a manual-inspection problem.
#
# Neither Azure nor AWS credentials are used or required: `az` and `aws` are
# shell functions defined below and exported (`export -f`), so any
# subprocess this script starts -- including preflight-aws.sh run as
# `bash preflight-aws.sh ...` -- calls the mock instead of a real CLI.
#
# Run: bash quickstart/tests/cloud_prereqs_test.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

pass=0; fail=0
check() {  # check <description> <actual> <expected>
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"; pass=$((pass+1))
  else
    printf '  FAIL %s\n       expected %q\n       got      %q\n' "$1" "$3" "$2"; fail=$((fail+1))
  fi
}
# run <description> <expected_exit> <scenario> <fn-or-cmd...>
# Runs the given command in a subshell (so a `die`/`exit` inside it cannot
# kill this test runner, even though deploy.sh's `set -e` is inherited once
# sourced) with MOCK_SCENARIO exported for the mock az/aws to read.
run() {
  local desc="$1" expected="$2" scenario="$3" rc=0
  shift 3
  ( export MOCK_SCENARIO="$scenario"; "$@" ) >/tmp/cpt_out.$$ 2>&1 || rc=$?
  if [ "$rc" -eq "$expected" ]; then
    printf '  ok   %s (exit %s)\n' "$desc" "$rc"; pass=$((pass+1))
  else
    printf '  FAIL %s: expected exit %s, got %s\n' "$desc" "$expected" "$rc"
    sed 's/^/       /' /tmp/cpt_out.$$
    fail=$((fail+1))
  fi
  rm -f /tmp/cpt_out.$$
}

# ---------------------------------------------------------------------------
# Mock az / aws. Behavior selected by MOCK_SCENARIO:
#   happy       - everything already registered/exists
#   partial     - one thing missing, rest already present
#   all_missing - everything missing, all creations/registrations succeed
#   fail_create - one creation/registration genuinely fails (AccessDenied)
# Exported so preflight-aws.sh, run as a separate `bash` subprocess below,
# calls these instead of a real CLI.
# ---------------------------------------------------------------------------
az() {
  local scenario="${MOCK_SCENARIO:-happy}"
  case "$1 $2" in
    "provider show")
      local ns=""
      shift 2
      while [ $# -gt 0 ]; do [ "$1" = "--namespace" ] && ns="$2"; shift; done
      case "$scenario" in
        partial) [ "$ns" = "Microsoft.Cache" ] && echo "NotRegistered" || echo "Registered" ;;
        all_missing|fail_create) echo "NotRegistered" ;;
        *) echo "Registered" ;;
      esac
      ;;
    "provider register")
      local ns=""
      shift 2
      while [ $# -gt 0 ]; do [ "$1" = "--namespace" ] && ns="$2"; shift; done
      if [ "$scenario" = fail_create ] && [ "$ns" = "Microsoft.Cache" ]; then
        echo "AuthorizationFailed" >&2; return 1
      fi
      return 0
      ;;
    *) echo "MOCK az: unhandled invocation: $*" >&2; return 1 ;;
  esac
}
aws() {
  local scenario="${MOCK_SCENARIO:-happy}"
  case "$1 $2" in
    "sts get-caller-identity")
      echo '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/mocktest"}'
      ;;
    "iam list-roles")
      local prefix=""
      shift 2
      while [ $# -gt 0 ]; do [ "$1" = "--path-prefix" ] && prefix="$2"; shift; done
      case "$scenario" in
        partial)
          case "$prefix" in *rds.amazonaws.com*) echo "AWSServiceRoleForRDS" ;; *) echo "None" ;; esac
          ;;
        all_missing|fail_create) echo "None" ;;
        *) echo "AWSServiceRoleForRDS" ;;
      esac
      ;;
    "iam create-service-linked-role")
      local svc=""
      shift 2
      while [ $# -gt 0 ]; do [ "$1" = "--aws-service-name" ] && svc="$2"; shift; done
      if [ "$scenario" = fail_create ] && [ "$svc" = "elasticache.amazonaws.com" ]; then
        echo "An error occurred (AccessDenied) when calling CreateServiceLinkedRole" >&2
        return 1
      fi
      return 0
      ;;
    "ec2 describe-images") echo "None" ;;
    "service-quotas get-service-quota") echo "64.0" ;;
    *) echo "MOCK aws: unhandled invocation: $*" >&2; return 1 ;;
  esac
}
export -f az aws

# ---------------------------------------------------------------------------
# deploy.sh, sourced as a library (same technique as deploy_test.sh)
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034
HAILBYTES_WIZARD_LIB=1 . "${REPO}/quickstart/deploy.sh"
confirm() { return 0; }  # user always says yes, so the register/create branch runs
export -f confirm

printf '\nPure tier -> requirement mapping\n'
check "azure single needs 8 providers"    "$(azure_providers_for_tier single | wc -l | tr -d ' ')" "8"
check "azure ha adds 2 (Postgres, Cache)" "$(azure_providers_for_tier ha | wc -l | tr -d ' ')" "10"
check "azure autoscale same as ha"        "$(azure_providers_for_tier autoscale | sort | md5sum)" "$(azure_providers_for_tier ha | sort | md5sum)"
check "aws single needs no SLRs"          "$(aws_service_linked_roles_for_tier single | grep -c .)" "0"
check "aws ha needs 3 SLRs"               "$(aws_service_linked_roles_for_tier ha | wc -l | tr -d ' ')" "3"
check "aws autoscale needs 4 SLRs"        "$(aws_service_linked_roles_for_tier autoscale | wc -l | tr -d ' ')" "4"

printf '\ncheck_cloud_prerequisites is wired into main() after pick_tier\n'
main_body="$(awk '/^main\(\) \{/,/^}/' "${REPO}/quickstart/deploy.sh")"
if [[ "$main_body" == *"pick_tier"*"check_cloud_prerequisites"* ]]; then
  printf '  ok   check_cloud_prerequisites runs, and after pick_tier\n'; pass=$((pass+1))
else
  printf '  FAIL check_cloud_prerequisites missing from main(), or runs before pick_tier is known\n'; fail=$((fail+1))
fi

printf '\ncheck_cloud_prerequisites: Azure, mocked az\n'
run "single, everything registered"        0 happy       check_cloud_prerequisites azure single
run "ha, mixed -> registers the rest"      0 partial     check_cloud_prerequisites azure ha
run "ha, all missing -> registers all"     0 all_missing check_cloud_prerequisites azure ha
run "ha, one cannot be registered -> dies" 1 fail_create check_cloud_prerequisites azure ha
run "autoscale, all missing"               0 all_missing check_cloud_prerequisites azure autoscale

printf '\ncheck_cloud_prerequisites: AWS, mocked aws\n'
run "single, needs nothing"             0 all_missing check_cloud_prerequisites aws single
run "ha, mixed -> creates the rest"     0 partial     check_cloud_prerequisites aws ha
run "ha, all missing -> creates all"    0 all_missing check_cloud_prerequisites aws ha
run "ha, one cannot be created -> dies" 1 fail_create check_cloud_prerequisites aws ha
run "autoscale, one cannot be created"  1 fail_create check_cloud_prerequisites aws autoscale

printf '\ncheck_cloud_prerequisites: declining leaves the wizard running rather than blocking\n'
(
  confirm() { return 1; }
  run "azure ha, user declines -> continues anyway" 0 all_missing check_cloud_prerequisites azure ha
  run "aws ha, user declines -> continues anyway"   0 all_missing check_cloud_prerequisites aws ha
)

printf '\npreflight-aws.sh, run as a real subprocess against the mock\n'
run "rejects an unknown tier"         2 happy       bash "${REPO}/quickstart/preflight-aws.sh" bogus
run "single tier needs no SLRs"       0 happy       bash "${REPO}/quickstart/preflight-aws.sh" single
run "ha tier, all missing -> creates" 0 all_missing bash "${REPO}/quickstart/preflight-aws.sh" ha
run "ha tier, one cannot be created"  1 fail_create bash "${REPO}/quickstart/preflight-aws.sh" ha

printf '\npreflight-aws.sh fails cleanly with no credentials\n'
(
  unset -f aws
  aws() { return 255; }  # simulates "not logged in" (no usable identity)
  export -f aws
  run "no AWS credentials -> exit 1, not a crash" 1 happy bash "${REPO}/quickstart/preflight-aws.sh" single
)

printf '\nStandalone-script provider/SLR lists stay in sync with deploy.sh\n'
# Azure: extract preflight-azure.sh's two arrays and compare, as a set, to
# deploy.sh's azure_providers_for_tier(ha) (the union of both arrays there).
preflight_azure_src="$(cat "${REPO}/quickstart/preflight-azure.sh")"
common="$(awk '/^COMMON_PROVIDERS=\(/,/^\)/' <<<"$preflight_azure_src" | grep -oE 'Microsoft\.[A-Za-z]+')"
ha_only="$(awk '/^HA_ONLY_PROVIDERS=\(/,/^\)/' <<<"$preflight_azure_src" | grep -oE 'Microsoft\.[A-Za-z]+')"
preflight_azure_ha_sorted="$(printf '%s\n%s\n' "$common" "$ha_only" | sort)"
deploy_azure_ha_sorted="$(azure_providers_for_tier ha | sort)"
check "preflight-azure.sh ha list == deploy.sh's" "$preflight_azure_ha_sorted" "$deploy_azure_ha_sorted"

# AWS: preflight-aws.sh names each service-linked-role principal exactly
# once, only inside its COMMON_ROLES/HA_ONLY_ROLES/AUTOSCALE_ONLY_ROLES
# declarations (confirmed by inspection: `grep -c amazonaws.com` == 4, one
# per role, nowhere else in the file) -- so a flat grep of the whole file is
# an exact, order-independent stand-in for "every role across all three
# arrays" without needing to parse array boundaries.
preflight_aws_autoscale_sorted="$(grep -oE '[a-z]+\.amazonaws\.com' "${REPO}/quickstart/preflight-aws.sh" | sort)"
deploy_aws_autoscale_sorted="$(aws_service_linked_roles_for_tier autoscale | sort)"
check "preflight-aws.sh autoscale list == deploy.sh's" "$preflight_aws_autoscale_sorted" "$deploy_aws_autoscale_sorted"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
