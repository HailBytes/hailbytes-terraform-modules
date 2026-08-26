#!/usr/bin/env bash
# HailBytes SAT/ASM -- AWS account preflight.
#
# Run this ONCE per AWS account (and per region you plan to deploy into), in
# AWS CloudShell, before the first terraform apply. It is idempotent:
# re-running it is harmless.
#
#   curl -fsSL https://raw.githubusercontent.com/hailbytes/hailbytes-terraform-modules/main/quickstart/preflight-aws.sh | bash -s -- ha
#
# Or, from a clone:
#
#   ./quickstart/preflight-aws.sh single      # single-VM tier
#   ./quickstart/preflight-aws.sh ha          # HA hot-hot tier (2 instances + RDS + ElastiCache)
#   ./quickstart/preflight-aws.sh autoscale   # unlimited-scale tier (ASG + RDS + ElastiCache)
#
# WHY THIS EXISTS
# AWS has no direct equivalent of Azure's subscription-scoped resource
# provider registration, but it has a real analogue: RDS, ElastiCache and
# Elastic Load Balancing each depend on a one-time, account-level
# service-linked role (an IAM role AWS itself uses to manage the service on
# your behalf). AWS normally creates the role for you, silently, the first
# time you touch that service -- PROVIDED the calling identity holds
# iam:CreateServiceLinkedRole. A least-privilege deploy role scoped down to
# "create EC2/RDS/ElastiCache resources" often does NOT include that action,
# because it looks like an IAM-admin permission rather than an
# EC2/RDS/ElastiCache one.
#
# Without the role, apply does not fail at the start the way an unregistered
# Azure provider does. It fails when Terraform tries to create the FIRST
# resource of that kind -- an aws_db_instance, an aws_elasticache_replication_group,
# or an aws_lb -- with an AccessDenied error that names the missing
# iam:CreateServiceLinkedRole action, not "you are missing a service-linked
# role". This script surfaces that up front instead.
#
# WHAT IT CHANGES
#   * Creates missing service-linked roles (account-scoped, one-time,
#     additive). Creating one does not create any billable resource.
#   * Nothing else. It creates no VPCs, instances, databases or IAM roles
#     beyond the service-linked roles above.
#
# KEEP IN SYNC WITH quickstart/deploy.sh's aws_service_linked_roles_for_tier --
# quickstart/tests/deploy_test.sh asserts they match.

set -uo pipefail

TIER="${1:-ha}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

case "$TIER" in
    single|ha|autoscale) ;;
    *)
        echo "usage: $0 {single|ha|autoscale}" >&2
        exit 2
        ;;
esac

# Marketplace product codes for the two listings. Keep in sync with
# quickstart/deploy.sh's AWS_PRODUCT_CODE / AWS_LISTING.
declare -A PRODUCT_CODE=( [sat]="d19hjbz3gakqdlonlf8twdmll" [asm]="1n57wg1f6735e30vj5fn420bp" )
declare -A LISTING=(
    [sat]="https://aws.amazon.com/marketplace/pp/prodview-yyk6iton3ghu4"
    [asm]="https://aws.amazon.com/marketplace/pp/prodview-66d5bswmbtfhs"
)

# Service-linked roles each tier genuinely depends on, as the AWS service
# principal the role is created under.
#
# The single-VM tier needs NONE of these: it has no RDS, no ElastiCache and
# no load balancer. Its EBS snapshot schedule uses aws_dlm_lifecycle_policy,
# but that resource's execution role (modules/single-vm/aws/main.tf
# aws_iam_role.dlm) is an ordinary IAM role the module creates itself, not a
# service-linked role, so DLM needs no entry here.
COMMON_ROLES=()
HA_ONLY_ROLES=(
    rds.amazonaws.com
    elasticache.amazonaws.com
    elasticloadbalancing.amazonaws.com
)
AUTOSCALE_ONLY_ROLES=(
    autoscaling.amazonaws.com
)

case "$TIER" in
    single)    ROLES=("${COMMON_ROLES[@]}") ;;
    ha)        ROLES=("${COMMON_ROLES[@]}" "${HA_ONLY_ROLES[@]}") ;;
    autoscale) ROLES=("${COMMON_ROLES[@]}" "${HA_ONLY_ROLES[@]}" "${AUTOSCALE_ONLY_ROLES[@]}") ;;
esac

echo "=============================================================="
echo " HailBytes -- AWS preflight (${TIER} tier, ${REGION})"
echo "=============================================================="
echo

# ---------- 1. Who are we, and where ----------
if ! IDENTITY_JSON="$(aws sts get-caller-identity --output json 2>/dev/null)"; then
    echo "ERROR: not logged in to the AWS CLI. In CloudShell this should already" >&2
    echo "       be done; otherwise run aws configure first." >&2
    exit 1
fi
ACCOUNT="$(printf '%s' "$IDENTITY_JSON" | grep -o '"Account": *"[^"]*"' | cut -d'"' -f4)"
ARN="$(printf '%s' "$IDENTITY_JSON" | grep -o '"Arn": *"[^"]*"' | cut -d'"' -f4)"

echo "Account : ${ACCOUNT}"
echo "Identity: ${ARN}"
echo "Region  : ${REGION}"
echo
echo "If that is not the account you intend to deploy into, stop now and"
echo "reconfigure your AWS CLI profile or CloudShell session."
echo

# ---------- 2. Service-linked roles ----------
echo "--------------------------------------------------------------"
echo " Service-linked roles"
echo "--------------------------------------------------------------"

if [ "${#ROLES[@]}" -eq 0 ]; then
    echo "The ${TIER} tier needs no service-linked roles beyond what every AWS"
    echo "account already has for EC2/IAM/KMS."
else
    to_create=()
    for svc in "${ROLES[@]}"; do
        found="$(aws iam list-roles --path-prefix "/aws-service-role/${svc}/" \
                   --query 'Roles[0].RoleName' --output text 2>/dev/null || true)"
        if [ -n "$found" ] && [ "$found" != "None" ]; then
            printf '  %-30s %s\n' "$svc" "already exists (${found})"
        else
            printf '  %-30s %s\n' "$svc" "does not exist yet"
            to_create+=("$svc")
        fi
    done
    echo

    if [ ${#to_create[@]} -eq 0 ]; then
        echo "all required service-linked roles already exist"
    else
        echo "Creating ${#to_create[@]} service-linked role(s). This is a one-time,"
        echo "account-scoped, non-billable change."
        echo
        failed=()
        for svc in "${to_create[@]}"; do
            printf '  creating %-30s ' "$svc"
            out="$(aws iam create-service-linked-role --aws-service-name "$svc" 2>&1)"
            rc=$?
            recheck="$(aws iam list-roles --path-prefix "/aws-service-role/${svc}/" \
                         --query 'Roles[0].RoleName' --output text 2>/dev/null || true)"
            if [ "$rc" -eq 0 ] || { [ -n "$recheck" ] && [ "$recheck" != "None" ]; }; then
                echo "done"
            else
                echo "FAILED"
                echo "    ${out}" | head -1
                failed+=("$svc")
            fi
        done
        echo
        if [ ${#failed[@]} -gt 0 ]; then
            echo "ERROR: could not create service-linked role(s) for: ${failed[*]}" >&2
            echo "" >&2
            echo "This is almost always a permissions problem, not a transient error." >&2
            echo "Creating a service-linked role needs iam:CreateServiceLinkedRole," >&2
            echo "which a least-privilege create-EC2/RDS/ElastiCache-resources role" >&2
            echo "often does not include, because it reads as an IAM-admin action." >&2
            echo "Ask someone with IAM admin rights to run:" >&2
            echo "" >&2
            for svc in "${failed[@]}"; do
                echo "  aws iam create-service-linked-role --aws-service-name ${svc}" >&2
            done
            exit 1
        fi
    fi
fi
echo

# ---------- 3. Marketplace subscription ----------
echo "--------------------------------------------------------------"
echo " Marketplace subscription"
echo "--------------------------------------------------------------"
echo "Checking both listings, since this script does not know which product"
echo "you intend to deploy:"
echo

for product in sat asm; do
    code="${PRODUCT_CODE[$product]}"
    ami="$(aws ec2 describe-images --owners aws-marketplace --region "$REGION" \
             --filters "Name=product-code,Values=${code}" \
             --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' \
             --output text 2>/dev/null || true)"
    if [ -n "$ami" ] && [ "$ami" != "None" ]; then
        printf '  %-4s %s\n' "$product" "AMI visible in ${REGION} (${ami})"
    else
        printf '  %-4s %s\n' "$product" "no AMI visible -- not yet subscribed, or not available in ${REGION}"
        printf '       subscribe: %s\n' "${LISTING[$product]}"
    fi
done
echo
echo "Unlike Azure, AWS Marketplace subscription has no CLI equivalent of"
echo "az vm image terms accept. Subscribing is a console action (the"
echo "listing page's Continue to Subscribe / Accept Terms button). The"
echo "module cannot do it for you on apply, and neither can this script."
echo

# ---------- 4. Service quota (informational) ----------
echo "--------------------------------------------------------------"
echo " EC2 vCPU quota (informational)"
echo "--------------------------------------------------------------"
quota="$(aws service-quotas get-service-quota --region "$REGION" \
           --service-code ec2 --quota-code L-1216C47A \
           --query 'Quota.Value' --output text 2>/dev/null || true)"
# The module default application-node size, and its vCPU count. Keep in sync
# with the instance_type defaults in modules/*/aws/variables.tf -- comparing
# against a size Terraform will not ask for is worse than not comparing.
INSTANCE_TYPE="m6i.2xlarge"
INSTANCE_VCPUS=8
case "$TIER" in
    ha)        node_count=2 ;;
    autoscale) node_count=2 ;;   # asg_desired_capacity default; max_size is the real ceiling
    *)         node_count=1 ;;
esac
needed=$(( node_count * INSTANCE_VCPUS ))

echo "The ${TIER} tier builds ${node_count} application instance(s) at"
echo "${INSTANCE_TYPE} (${INSTANCE_VCPUS} vCPUs each) by default, so it needs"
echo "${needed} vCPUs of Standard on-demand quota here."
echo

if [ -n "$quota" ] && [ "$quota" != "None" ]; then
    echo "Running On-Demand Standard (A/C/D/H/I/M/R/T/Z) instance vCPU limit in"
    echo "${REGION}: ${quota}"
    # Service Quotas reports the LIMIT; current consumption needs CloudWatch and
    # a different permission, so this can only catch a limit that is too small
    # outright -- not one already consumed by other workloads.
    quota_int="${quota%%.*}"
    if [ -n "$quota_int" ] && [ "$quota_int" -eq "$quota_int" ] 2>/dev/null && [ "$quota_int" -lt "$needed" ]; then
        echo
        echo "  NOT ENOUGH. The limit itself (${quota_int}) is below the ${needed} vCPUs"
        echo "  this tier needs, before anything else in the account is counted."
        echo "  Request an increase in the Service Quotas console before the"
        echo "  deployment call -- approval is not instant."
    else
        echo "  At or above the ${needed} vCPUs this tier needs. Note this is the"
        echo "  LIMIT, not the headroom: other running instances count against it"
        echo "  and Service Quotas does not report current consumption."
    fi
else
    echo "Could not read the quota (Service Quotas read access may be missing)."
    echo "Check by hand before deploying -- this tier needs ${needed} vCPUs:"
    echo "  aws service-quotas get-service-quota --region ${REGION} \\"
    echo "    --service-code ec2 --quota-code L-1216C47A"
fi
if [ "$TIER" = ha ]; then
    echo "The RDS instance and the ElastiCache replication group draw their own"
    echo "quotas, separate from this one."
elif [ "$TIER" = autoscale ]; then
    echo "The figure above is the ASG's DESIRED capacity. Its ceiling is whatever"
    echo "you set asg_max_size to, so size the quota against max_size x"
    echo "${INSTANCE_VCPUS} vCPUs, not against ${needed}."
fi
echo "New accounts sometimes start with a default of a few dozen vCPUs; request"
echo "an increase via the Service Quotas console if you expect to be close to it."
echo

# ---------- 5. Permissions the deploying identity needs ----------
echo "--------------------------------------------------------------"
echo " Permissions the deploying identity needs"
echo "--------------------------------------------------------------"
echo "Beyond the service-linked roles above, every tier creates its own"
echo "least-privilege IAM role and instance profile for the EC2 instance(s) --"
echo "so the deploying identity itself needs iam:CreateRole, iam:PutRolePolicy,"
echo "iam:AttachRolePolicy, iam:CreateInstanceProfile and iam:PassRole, on top"
echo "of create/read/write on EC2, EBS, KMS, Secrets Manager, CloudWatch Logs"
echo "and SNS."
if [ "$TIER" != single ]; then
    echo "The ${TIER} tier additionally needs RDS, ElastiCache and"
    echo "elasticloadbalancing:* create permissions."
fi
if [ "$TIER" = autoscale ]; then
    echo "The autoscale tier additionally needs EC2 Auto Scaling and launch"
    echo "template create permissions."
fi
echo
echo "This is the AWS analogue of Azure needing User Access Administrator on"
echo "top of Contributor: a role scoped narrowly to create-the-resources can"
echo "still lack the IAM-admin-shaped permissions those resources need, and it"
echo "surfaces late -- after some resources already exist."
echo

echo "=============================================================="
echo " Preflight complete for the ${TIER} tier."
echo "=============================================================="
