#!/usr/bin/env bash
# HailBytes — empty an S3 bucket so terraform destroy can delete it.
#
#   ./quickstart/empty-bucket-aws.sh <bucket> [--region R]
#
# WHY THIS EXISTS
# The AWS modules create buckets that terraform destroy cannot delete while
# they hold anything, by design:
#
#   *-backups-<account>   pre-patch backup bundles. Versioned, Object Lock in
#                         GOVERNANCE mode, force_destroy = false. Destroy fails
#                         with BucketNotEmpty once a single backup exists.
#   *-alb-logs-<account>  load-balancer access logs (always on in autoscale).
#                         Versioned, force_destroy = false, and filling up from
#                         the first request.
#
# Emptying a versioned bucket means deleting every object VERSION and every
# delete marker, which `aws s3 rm --recursive` does not do; and the backup
# bucket's GOVERNANCE lock additionally needs s3:BypassGovernanceRetention.
# This does both.
#
# GUARD RAILS
#   * Refuses any bucket without a Product tag starting "hailbytes-", which
#     every bucket these modules create carries. It will not empty a bucket the
#     modules did not make.
#   * Prints what it is about to delete and asks you to type the bucket name.
#     There is no --force.
#
# Deleting backups is irreversible. Take the export first (the runbook's
# Step 10, point 1) if there is anything you want to keep.

set -uo pipefail

BUCKET=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
while [ $# -gt 0 ]; do
    case "$1" in
        --region)   [ $# -ge 2 ] || { echo "--region needs a value" >&2; exit 2; }; REGION="$2"; shift ;;
        --region=*) REGION="${1#--region=}" ;;
        -h|--help)  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)         echo "unknown option: $1" >&2; exit 2 ;;
        *)          [ -z "$BUCKET" ] || { echo "one bucket at a time" >&2; exit 2; }; BUCKET="$1" ;;
    esac
    shift
done
[ -n "$BUCKET" ] || { echo "usage: $0 <bucket> [--region R]" >&2; exit 2; }

command -v aws >/dev/null || { echo "ERROR: aws CLI not found." >&2; exit 1; }

product="$(aws s3api get-bucket-tagging --bucket "$BUCKET" --region "$REGION" \
             --query "TagSet[?Key=='Product'].Value | [0]" --output text 2>/dev/null || true)"
case "$product" in
    hailbytes-*) : ;;
    *)
        echo "REFUSED: ${BUCKET} has no Product=hailbytes-* tag (got '${product:-none}')." >&2
        echo "This script only empties buckets the HailBytes modules created." >&2
        exit 1
        ;;
esac

count="$(aws s3api list-object-versions --bucket "$BUCKET" --region "$REGION" \
           --query 'length([Versions,DeleteMarkers][][])' --output text 2>/dev/null || echo "?")"
echo "Bucket   ${BUCKET}  (${product}, ${REGION})"
echo "Holds    ${count} object version(s) and delete marker(s), all of which will be deleted."
echo "This cannot be undone."
printf 'Type the bucket name to continue: '
read -r typed || typed=""
[ "$typed" = "$BUCKET" ] || { echo "Names did not match; nothing deleted."; exit 1; }

deleted=0
while :; do
    batch="$(aws s3api list-object-versions --bucket "$BUCKET" --region "$REGION" --max-items 1000 \
               --query '{Objects: [Versions,DeleteMarkers][][].{Key: Key, VersionId: VersionId}, Quiet: `true`}' \
               --output json 2>/dev/null)" || { echo "ERROR: could not list ${BUCKET}." >&2; exit 1; }
    case "$batch" in *'"Key"'*) : ;; *) break ;; esac
    n="$(printf '%s' "$batch" | grep -o '"Key"' | wc -l | tr -d ' ')"
    if ! out="$(aws s3api delete-objects --bucket "$BUCKET" --region "$REGION" \
                  --bypass-governance-retention --delete "$batch" --output json 2>&1)"; then
        echo "ERROR: delete failed:" >&2
        printf '%s\n' "$out" | sed 's/^/  /' >&2
        echo "Deleting from the backup bucket needs s3:BypassGovernanceRetention." >&2
        exit 1
    fi
    if printf '%s' "$out" | grep -q '"Errors"'; then
        echo "ERROR: some objects were not deleted:" >&2
        printf '%s\n' "$out" | sed 's/^/  /' >&2
        echo "Deleting from the backup bucket needs s3:BypassGovernanceRetention." >&2
        exit 1
    fi
    deleted=$((deleted + n))
    echo "  deleted ${deleted} so far"
done
echo "Empty. terraform destroy can now remove ${BUCKET}."
