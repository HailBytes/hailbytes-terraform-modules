#!/usr/bin/env bash
#
# Tests for the AWS state bootstrap and bucket-emptying helpers, against a
# mocked aws CLI. No credentials, no network.
#
# Run: bash quickstart/tests/aws_helpers_test.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export MOCK_LOG="${WORK}/calls.log"
export MOCK_STATE="${WORK}/state"

pass=0; fail=0
check() {  # check <description> <actual> <expected>
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; pass=$((pass+1))
    else printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$3" "$2"; fail=$((fail+1)); fi
}
has() {  # has <description> <needle> <haystack>
    if printf '%s' "$3" | grep -qF -- "$2"; then printf '  ok   %s\n' "$1"; pass=$((pass+1))
    else printf '  FAIL %s\n       expected to find: %s\n' "$1" "$2"; fail=$((fail+1)); fi
}

# Every call is logged, one per line, so tests can assert what was (and was
# not) asked of AWS.
aws() {
    printf '%s\n' "$*" >> "$MOCK_LOG"
    case "$1 $2" in
        "sts get-caller-identity") echo "123456789012" ;;
        "s3api head-bucket") [ "${MOCK_BUCKET_EXISTS:-0}" = 1 ] ;;
        "s3api get-bucket-tagging") echo "${MOCK_PRODUCT_TAG:-None}" ;;
        "s3api list-object-versions")
            case "$*" in
                *length*) echo 2 ;;
                *)
                    if [ -f "$MOCK_STATE" ]; then echo '{"Objects": [], "Quiet": true}'
                    else echo '{"Objects": [{"Key": "a", "VersionId": "1"}, {"Key": "b", "VersionId": "2"}], "Quiet": true}'; fi
                    ;;
            esac
            ;;
        "s3api delete-objects") touch "$MOCK_STATE"; echo '{}' ;;
        "s3api "*) return 0 ;;
        *) echo "MOCK aws: unhandled $*" >&2; return 1 ;;
    esac
}
export -f aws

BOOT="${REPO}/quickstart/bootstrap-state-aws.sh"
EMPTY="${REPO}/quickstart/empty-bucket-aws.sh"

echo "bootstrap-state-aws.sh"
bash "$BOOT" --nope >/dev/null 2>&1; check "rejects an unknown option" "$?" "2"
bash "$BOOT" --print-only >/dev/null 2>&1; check "--print-only without --bucket fails" "$?" "1"
o="$(bash "$BOOT" --print-only --bucket b1 --key clients/acme/sat-ha.tfstate --region eu-west-1)"
has "print-only names the bucket"     'bucket  = "b1"' "$o"
has "print-only names the client key" 'key     = "clients/acme/sat-ha.tfstate"' "$o"
has "print-only uses native locking"  'use_lockfile = true' "$o"

: > "$MOCK_LOG"
o="$(bash "$BOOT" --out "$WORK/us" --region us-east-1 --key k 2>&1)"; rc=$?
check "us-east-1 run succeeds" "$rc" "0"
has "derives the bucket name from account and region" "hailbytes-tfstate-123456789012-us-east-1" "$o"
check "us-east-1 create sends no LocationConstraint" "$(grep 'create-bucket' "$MOCK_LOG" | grep -c LocationConstraint)" "0"
check "versioning is enabled" "$(grep -c 'put-bucket-versioning.*Status=Enabled' "$MOCK_LOG")" "1"
check "public access is blocked" "$(grep -c 'put-public-access-block' "$MOCK_LOG")" "1"
check "TLS-only policy is applied" "$(grep -c 'aws:SecureTransport' "$MOCK_LOG")" "1"
has "backend.tf written" 'use_lockfile = true' "$(cat "$WORK/us/backend.tf")"

: > "$MOCK_LOG"
bash "$BOOT" --out "$WORK/eu" --region eu-west-1 --key k >/dev/null 2>&1
check "other regions send their LocationConstraint" "$(grep -c 'LocationConstraint=eu-west-1' "$MOCK_LOG")" "1"

: > "$MOCK_LOG"
MOCK_BUCKET_EXISTS=1 bash "$BOOT" --out "$WORK/again" --key k2 >/dev/null 2>&1
check "an existing bucket is reused, not re-created" "$(grep -c 'create-bucket' "$MOCK_LOG")" "0"

echo "empty-bucket-aws.sh"
bash "$EMPTY" >/dev/null 2>&1; check "needs a bucket" "$?" "2"

: > "$MOCK_LOG"; rm -f "$MOCK_STATE"
echo "somebucket" | MOCK_PRODUCT_TAG=None bash "$EMPTY" somebucket >/dev/null 2>&1; rc=$?
check "refuses a bucket without a hailbytes Product tag" "$rc" "1"
check "  ...and deletes nothing" "$(grep -c 'delete-objects' "$MOCK_LOG")" "0"

: > "$MOCK_LOG"; rm -f "$MOCK_STATE"
echo "wrong-name" | MOCK_PRODUCT_TAG=hailbytes-sat bash "$EMPTY" acme-sat-prod-backups-1 >/dev/null 2>&1; rc=$?
check "a mistyped confirmation stops it" "$rc" "1"
check "  ...and deletes nothing" "$(grep -c 'delete-objects' "$MOCK_LOG")" "0"

: > "$MOCK_LOG"; rm -f "$MOCK_STATE"
o="$(echo "acme-sat-prod-backups-1" | MOCK_PRODUCT_TAG=hailbytes-sat bash "$EMPTY" acme-sat-prod-backups-1 2>&1)"; rc=$?
check "the typed name empties the bucket" "$rc" "0"
check "  ...bypassing GOVERNANCE retention" "$(grep 'delete-objects' "$MOCK_LOG" | grep -c -- '--bypass-governance-retention')" "1"
has "  ...and reports what it deleted" "deleted 2 so far" "$o"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
