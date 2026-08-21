#!/usr/bin/env bash
#
# HailBytes guided deployment — AWS and Azure Cloud Shell.
#
#   Azure:  bash <(curl -fsSL https://raw.githubusercontent.com/HailBytes/hailbytes-terraform-modules/main/quickstart/deploy.sh)
#   AWS:    same command; the script detects which Cloud Shell it is in.
#
# What it does, in order:
#   1. Detects the cloud and checks the tools it needs are present.
#   2. Checks whether you have an active Marketplace subscription for the
#      product, and links the listing if you don't.
#   3. Asks how you want to deploy — product, tier, region, database backend —
#      warning explicitly before any answer that changes the bill materially.
#   4. Writes a terraform.tfvars and a root module, shows you the plan, and
#      applies only after you type the confirmation.
#
# It never applies anything without showing you a plan first, and it never
# picks a billing-relevant option for you silently.
#
# This script is MPL-2.0 like the rest of the repo. The VM images it deploys
# are commercial software billed through AWS or Azure Marketplace.

set -euo pipefail

REPO_GIT="github.com/HailBytes/hailbytes-terraform-modules"
WORKDIR="${HAILBYTES_WORKDIR:-$HOME/hailbytes-deploy}"

# Marketplace listings, so we can send someone straight to the subscribe page.
AZURE_PUBLISHER="lcmcon1687976613543"
declare -A AZURE_OFFER=( [sat]="gophish-phishing-simulator" [asm]="hardened_ubuntu_with_rengine" )
declare -A AZURE_LISTING=(
  [sat]="https://marketplace.microsoft.com/en-us/product/virtual-machines/lcmcon1687976613543.gophish-phishing-simulator"
  [asm]="https://marketplace.microsoft.com/en-us/product/virtual-machines/lcmcon1687976613543.hardened_ubuntu_with_rengine"
)
declare -A AWS_PRODUCT_CODE=( [sat]="d19hjbz3gakqdlonlf8twdmll" [asm]="1n57wg1f6735e30vj5fn420bp" )
declare -A AWS_LISTING=(
  [sat]="https://aws.amazon.com/marketplace/pp/prodview-yyk6iton3ghu4"
  [asm]="https://aws.amazon.com/marketplace/pp/prodview-66d5bswmbtfhs"
)

# The per-vCPU Marketplace meter. Used only to show the operator what their
# choices cost; billing itself is the cloud's, not ours.
METER_PER_VCPU_HOUR="0.24"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYN=$'\033[36m'
else
  B=''; DIM=''; R=''; RED=''; GRN=''; YLW=''; CYN=''
fi

say()  { printf '%s\n' "$*"; }
head2() { printf '\n%s%s%s\n' "$B" "$*" "$R"; }
ok()   { printf '%s✓%s %s\n' "$GRN" "$R" "$*"; }
warn() { printf '%s!%s %s\n' "$YLW" "$R" "$*"; }
die()  { printf '%s✗ %s%s\n' "$RED" "$*" "$R" >&2; exit 1; }
note() { printf '%s%s%s\n' "$DIM" "$*" "$R"; }

# A cost warning that the operator has to acknowledge. Everything that can
# multiply a bill goes through this, because "may increase usage costs" in a
# price list is not the same as seeing the number before you agree to it.
cost_warning() {
  local headline="$1"; shift
  printf '\n%s┌─ COST IMPACT ─────────────────────────────────────────────%s\n' "$YLW" "$R"
  printf '%s│%s %s\n' "$YLW" "$R" "$headline"
  local line
  for line in "$@"; do printf '%s│%s   %s\n' "$YLW" "$R" "$line"; done
  printf '%s└───────────────────────────────────────────────────────────%s\n' "$YLW" "$R"
}

ask() {  # ask <prompt> <default> -> echoes answer
  local prompt="$1" default="${2:-}" reply
  if [ -n "$default" ]; then
    read -r -p "$(printf '%s%s%s [%s]: ' "$CYN" "$prompt" "$R" "$default")" reply || true
    printf '%s' "${reply:-$default}"
  else
    read -r -p "$(printf '%s%s%s: ' "$CYN" "$prompt" "$R")" reply || true
    printf '%s' "$reply"
  fi
}

confirm() {  # confirm <prompt> ; default no
  local reply
  read -r -p "$(printf '%s%s%s [y/N]: ' "$CYN" "$1" "$R")" reply || true
  [[ "${reply,,}" == y* ]]
}

choose() {  # choose <prompt> <opt1> <opt2> ... -> echoes chosen option
  local prompt="$1"; shift
  local opts=("$@") i reply
  printf '\n%s%s%s\n' "$B" "$prompt" "$R" >&2
  for i in "${!opts[@]}"; do printf '  %s%d)%s %s\n' "$CYN" $((i+1)) "$R" "${opts[$i]%%|*}" >&2; done
  while true; do
    read -r -p "$(printf 'Choice [1-%d]: ' "${#opts[@]}")" reply >&2 || true
    if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#opts[@]} )); then
      printf '%s' "${opts[$((reply-1))]}"
      return
    fi
    printf 'Enter a number between 1 and %d.\n' "${#opts[@]}" >&2
  done
}

# ---------------------------------------------------------------------------
# 1. Detect the cloud and check prerequisites
# ---------------------------------------------------------------------------
detect_cloud() {
  if [ -n "${HAILBYTES_CLOUD:-}" ]; then printf '%s' "$HAILBYTES_CLOUD"; return; fi
  if [ -n "${AZUREPS_HOST_ENVIRONMENT:-}" ] || [ -n "${ACC_CLOUD:-}" ]; then printf 'azure'; return; fi
  if [ -n "${AWS_EXECUTION_ENV:-}" ] || [ -n "${AWS_REGION:-}" ] || [ -d /aws/mde ]; then printf 'aws'; return; fi
  if command -v az >/dev/null 2>&1 && ! command -v aws >/dev/null 2>&1; then printf 'azure'; return; fi
  if command -v aws >/dev/null 2>&1 && ! command -v az >/dev/null 2>&1; then printf 'aws'; return; fi
  printf 'unknown'
}

check_prereqs() {
  local cloud="$1" missing=()
  command -v terraform >/dev/null 2>&1 || missing+=("terraform")
  command -v git >/dev/null 2>&1        || missing+=("git")
  if [ "$cloud" = azure ]; then
    command -v az >/dev/null 2>&1 || missing+=("az")
  else
    command -v aws >/dev/null 2>&1 || missing+=("aws")
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    die "Missing required tools: ${missing[*]}
   Both AWS and Azure Cloud Shell ship all of these. If you are running this
   outside Cloud Shell, install them and re-run."
  fi
  ok "terraform $(terraform version -json 2>/dev/null | grep -o '\"terraform_version\":\"[^\"]*' | cut -d'\"' -f4 || echo present)"

  if [ "$cloud" = azure ]; then
    az account show >/dev/null 2>&1 || die "Not signed in to Azure. Run: az login"
    AZ_SUB_ID="$(az account show --query id -o tsv)"
    AZ_SUB_NAME="$(az account show --query name -o tsv)"
    ok "Azure subscription: ${AZ_SUB_NAME} (${AZ_SUB_ID})"
  else
    aws sts get-caller-identity >/dev/null 2>&1 || die "No usable AWS credentials. Run: aws configure"
    AWS_ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
    ok "AWS account: ${AWS_ACCOUNT}"
  fi
}

# ---------------------------------------------------------------------------
# 2. Marketplace subscription check
# ---------------------------------------------------------------------------
# Neither cloud exposes a clean "am I subscribed?" API to a normal caller, so
# we do the best available proxy: on Azure, try to read the image version (an
# unsubscribed offer returns nothing); on AWS, try to resolve the AMI by
# product code. Either way, an inconclusive answer prints the listing link and
# asks rather than blocking.
check_marketplace_subscription() {
  local cloud="$1" product="$2" region="$3"

  head2 "Marketplace subscription"
  if [ "$cloud" = azure ]; then
    local offer="${AZURE_OFFER[$product]}" found=""
    note "Checking for a published image version of ${AZURE_PUBLISHER}/${offer} in ${region}…"
    found="$(az vm image list --publisher "$AZURE_PUBLISHER" --offer "$offer" \
               --location "$region" --all --query '[0].version' -o tsv 2>/dev/null || true)"
    if [ -n "$found" ] && [ "$found" != "None" ]; then
      ok "Image visible in ${region} (latest: ${found})"
      MARKETPLACE_LATEST="$found"
      return 0
    fi
    warn "Could not see a published image for this offer in ${region}."
    say ""
    say "That usually means one of two things:"
    say "  • the subscription has not accepted the Marketplace terms yet, or"
    say "  • the offer is not available in ${region}."
    say ""
    say "  Subscribe here: ${B}${AZURE_LISTING[$product]}${R}"
    say ""
    note "The module accepts terms for you on apply (accept_marketplace_terms = true),"
    note "which needs your account to be allowed to accept legal terms. If apply fails"
    note "with a terms error, accept them once from the listing page above and re-run."
  else
    local code="${AWS_PRODUCT_CODE[$product]}" ami=""
    note "Checking for an AMI with product code ${code} in ${region}…"
    ami="$(aws ec2 describe-images --owners aws-marketplace --region "$region" \
             --filters "Name=product-code,Values=${code}" \
             --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' \
             --output text 2>/dev/null || true)"
    if [ -n "$ami" ] && [ "$ami" != "None" ]; then
      ok "AMI visible in ${region}: ${ami}"
      MARKETPLACE_LATEST="$ami"
      return 0
    fi
    warn "Could not resolve an AMI for this product code in ${region}."
    say ""
    say "  Subscribe here: ${B}${AWS_LISTING[$product]}${R}"
    say ""
    note "AWS requires an accepted subscription before the AMI becomes visible to"
    note "your account. Subscribe, wait a minute, then re-run this script."
  fi

  if ! confirm "Continue anyway?"; then
    die "Stopped. Subscribe to the listing above, then re-run."
  fi
}

# ---------------------------------------------------------------------------
# 3. Deployment questions
# ---------------------------------------------------------------------------
pick_product() {
  local c
  c="$(choose "Which product are you deploying?" \
    "HailBytes SAT — phishing simulation and security awareness training|sat" \
    "HailBytes ASM — attack surface management|asm")"
  PRODUCT="${c##*|}"
}

pick_tier() {
  local c
  c="$(choose "Which deployment shape?" \
    "Single VM — one instance, local database. Dev, PoC, small org.|single" \
    "HA hot-hot — two instances across zones, managed database, shared cache.|ha" \
    "Unlimited scale — autoscaling instance group, managed database + read replicas.|autoscale")"
  TIER="${c##*|}"

  case "$TIER" in
    ha)
      cost_warning "HA is roughly 2.8x the all-in cost of a single VM." \
        "It is not 2x: HA adds a zone-redundant database (billed at 2x compute" \
        "AND 2x storage for the standby), a shared cache, and a load balancer." \
        "" \
        "At 2-vCPU instances in North Europe that is about \$1,432/month all-in" \
        "against \$514 for a single VM. See AZURE_COST_SHAPES.md for the" \
        "line-by-line breakdown and the levers that reduce it."
      confirm "Understood — continue with HA?" || exit 0
      ;;
    autoscale)
      cost_warning "Autoscale is the most expensive shape, and its ceiling is set by you." \
        "The instance group defaults to a minimum of 3 instances, and every" \
        "instance meters at \$${METER_PER_VCPU_HOUR}/vCPU-hour on top of cloud costs." \
        "" \
        "The database also defaults to a zone-redundant primary PLUS 2 read" \
        "replicas. On a 3-instance deployment that is usually over-provisioned:" \
        "each replica is a full server, and dropping from 2 to 0 saves about" \
        "\$7,700/year with no change to the capacity you bought." \
        "" \
        "You will be asked for min/max instance counts and replica count next."
      confirm "Understood — continue with autoscale?" || exit 0
      ;;
  esac
}

pick_region() {
  local default_region
  if [ "$CLOUD" = azure ]; then default_region="northeurope"; else default_region="${AWS_REGION:-eu-west-1}"; fi
  REGION="$(ask "Region" "$default_region")"
  [ -n "$REGION" ] || die "A region is required."
}

pick_db_mode() {
  # Only HA and autoscale have a database decision; single-vm uses the
  # database inside the image.
  if [ "$TIER" = single ]; then
    DB_MODE=""
    note "Single-VM uses the PostgreSQL instance inside the image. No database decision needed."
    return
  fi

  local managed_label vm_label
  if [ "$CLOUD" = azure ]; then
    managed_label="flexible_server"; vm_label="vm"
  else
    managed_label="rds"; vm_label="ec2"
  fi

  local c
  c="$(choose "How should the database be provisioned?" \
    "Managed, zone-redundant — recommended. Automated backups, point-in-time restore, automatic failover.|${managed_label}" \
    "Self-managed on a dedicated VM — you run PostgreSQL. No automated backups, no PITR, no failover.|${vm_label}" \
    "External — connect to a PostgreSQL server you already operate. We provision no database.|external")"
  DB_MODE="${c##*|}"

  case "$DB_MODE" in
    "$managed_label")
      cost_warning "The managed database is usually the largest single line in the bill." \
        "Zone-redundant HA bills 2x compute and 2x storage, because the standby" \
        "is a full server. At the HA default that is about \$321/month." \
        "" \
        "Two things that are NOT savings, so you are not surprised later:" \
        "  • SameZone HA costs the same as ZoneRedundant — it trades SLA for" \
        "    latency, not price." \
        "  • Storage can grow but never shrink. Over-provisioning on day one is" \
        "    permanent for the life of the server." \
        "" \
        "Reserved capacity cuts database compute 40% (1yr) or 60% (3yr) and is" \
        "the single biggest lever. Ask your account team before you commit."
      ;;
    "$vm_label")
      cost_warning "A self-managed database VM is cheaper infrastructure AND a lower total." \
        "The database VM boots plain Canonical Ubuntu with apt-installed" \
        "PostgreSQL, not the HailBytes Marketplace image, so it does NOT carry" \
        "the per-vCPU meter. Only nodes running the Marketplace image meter." \
        "" \
        "You also give up automated backups, point-in-time restore, and" \
        "zone-redundant failover. Choose this for compliance or BYO-DBA reasons," \
        "not to save money."
      confirm "Understood — you will operate this database yourself?" || exit 0
      ;;
    external)
      cost_warning "External mode removes the database from your cloud bill entirely." \
        "Worth \$3,500-39,000/year depending on size — the largest single saving" \
        "available, and it costs HailBytes nothing, so we are happy to support it." \
        "" \
        "In exchange, availability, backups, point-in-time restore and patching" \
        "for the database become YOURS. The pre-patch routine will not snapshot a" \
        "server we do not own." \
        "" \
        "Do not choose this for a mission-critical HA deployment unless your" \
        "PostgreSQL is genuinely highly available."
      confirm "Understood — you will operate the database yourself?" || exit 0
      EXT_DB_HOST="$(ask "PostgreSQL host (resolvable from the workload subnet)")"
      [ -n "$EXT_DB_HOST" ] || die "External mode needs a host."
      EXT_DB_PORT="$(ask "PostgreSQL port" "5432")"
      EXT_DB_NAME="$(ask "Database name (must already exist)" "hailbytes")"
      EXT_DB_USER="$(ask "Role to connect as (needs DDL rights — the app runs migrations)" "hailbytes")"
      read -r -s -p "$(printf '%sPassword for %s%s: ' "$CYN" "$EXT_DB_USER" "$R")" EXT_DB_PASS; echo
      [ -n "$EXT_DB_PASS" ] || die "External mode needs a password."
      ;;
  esac
}

pick_scale_knobs() {
  [ "$TIER" = autoscale ] || return 0
  MIN_COUNT="$(ask "Minimum instances" "2")"
  MAX_COUNT="$(ask "Maximum instances the autoscaler may reach" "$MIN_COUNT")"
  if [ "$MAX_COUNT" -gt "$MIN_COUNT" ] 2>/dev/null; then
    # 8 vCPU per node: the module default is the 8-vCore training floor
    # (m6i.2xlarge / Standard_D8s_v5). This was hardcoded at 2 when the
    # defaults shipped below the floor.
    local extra=$(( (MAX_COUNT - MIN_COUNT) * 8 ))
    cost_warning "Autoscaling is enabled: max ${MAX_COUNT} instances." \
      "Scaling out meters every extra instance. At 8 vCPU per instance that is" \
      "up to ${extra} additional metered vCPUs, roughly" \
      "\$$(awk "BEGIN{printf \"%.0f\", ${extra}*730*${METER_PER_VCPU_HOUR}}")/month on top of your baseline if it" \
      "sits at maximum." \
      "" \
      "Set max = min if you want a fixed-capacity deployment with no scaling" \
      "surprises. You can raise it later."
    confirm "Keep max at ${MAX_COUNT}?" || MAX_COUNT="$MIN_COUNT"
  fi

  if [ "$DB_MODE" != external ]; then
    REPLICAS="$(ask "Database read replicas (0-5; the module default is 2)" "0")"
    if [ "${REPLICAS:-0}" -gt 0 ] 2>/dev/null; then
      cost_warning "${REPLICAS} read replica(s) requested." \
        "Each replica is a full database server plus its own storage — about" \
        "\$321/month each at the autoscale default size, so roughly" \
        "\$$(awk "BEGIN{printf \"%.0f\", ${REPLICAS}*3858}")/year for ${REPLICAS}." \
        "" \
        "A 3-instance deployment rarely needs read replicas at all. They only" \
        "help if the application is configured to route reads to them."
      confirm "Keep ${REPLICAS} replica(s)?" || REPLICAS=0
    fi
  fi
}

pick_frontend() {
  [ "$TIER" = single ] && return 0
  [ "$CLOUD" = azure ] || return 0

  say ""
  note "By default the load balancer passes TCP 443 straight through to the VMs,"
  note "which present a self-signed certificate — browsers will warn on every visit."
  if confirm "Front the deployment with an Application Gateway (real TLS + optional WAF)?"; then
    APPGW=true
    cost_warning "Application Gateway is an additional fixed monthly cost." \
      "Standard_v2 is about \$187/month; with a WAF policy attached, WAF_v2 is" \
      "about \$336/month. That is 10-18x the Standard Load Balancer it sits in" \
      "front of, and the load balancer stays in the topology." \
      "" \
      "If you already run Azure Front Door or your own reverse proxy with a" \
      "valid certificate, point that at the deployment instead and answer no."
    confirm "Continue with Application Gateway?" || APPGW=false
    if [ "$APPGW" = true ]; then
      note "You will need a PFX bundle and a dedicated /24 subnet for the gateway."
      note "Set appgw_tls_pfx_base64, appgw_tls_pfx_password and appgw_subnet_id in"
      note "the generated terraform.tfvars before applying."
    fi
  else
    APPGW=false
  fi
}

warn_about_egress() {
  [ "$CLOUD" = azure ] || return 0
  say ""
  note "A NAT Gateway is created for outbound traffic — without one the VMs cannot"
  note "reach anything, including SMTP and OS updates. It costs about \$33/month plus"
  note "\$0.045/GB processed. That per-GB charge applies to traffic bound for Azure's"
  note "own services too, so the module adds service endpoints where it can."
}

# The Key Vault trap. Azure Key Vault names are globally unique, and this module
# creates the vault with purge protection and a 30-day soft-delete window
# (a disk encryption set requires purge protection, so it cannot be turned off).
# Destroy a deployment and re-create it under the same name inside 30 days and
# the apply fails, with no force-purge available — you wait, or you rename.
#
# The people running this wizard are exactly the people who will destroy and
# redeploy a PoC next week, so ask up front rather than let them find out.
pick_key_vault_name() {
  KEY_VAULT_NAME=""
  [ "$CLOUD" = azure ] || return 0
  [ "$TIER" = ha ] || [ "$TIER" = autoscale ] || return 0

  say ""
  head2 "Key Vault naming"
  warn "Azure Key Vault names are global, and this deployment's vault is created with"
  warn "purge protection and a 30-day soft-delete window that cannot be waived."
  note "If you destroy this deployment and re-create it under the same name within"
  note "30 days, the apply FAILS and cannot be forced. A unique name per attempt"
  note "avoids that entirely and costs nothing."

  if confirm "Is this a trial or PoC you might tear down and re-create?"; then
    # Date-stamped, since a wizard run is what identifies an attempt. 24-char
    # limit, alphanumerics only.
    local suffix
    suffix="$(date -u +%m%d%H%M)"
    KEY_VAULT_NAME="$(printf 'hb%s%s' "$PRODUCT" "$suffix" | cut -c1-24)"
    ok "Vault will be named ${KEY_VAULT_NAME} — unique to this run."
    note "Keep this value if you re-run terraform against the same deployment;"
    note "changing it later REPLACES the vault holding your database password."
  else
    note "Using the module's derived name. If you later need to rebuild from"
    note "scratch, set key_vault_name to something new in main.tf first."
  fi
}

# The cache this deploys is a service Microsoft has dated. Say so at deploy time,
# not after the customer has built a three-year plan on it.
warn_about_redis_retirement() {
  [ "$CLOUD" = azure ] || return 0
  [ "$TIER" = ha ] || [ "$TIER" = autoscale ] || return 0

  say ""
  head2 "One thing to know about the cache"
  warn "Azure Cache for Redis is being retired by Microsoft."
  note "Basic / Standard / Premium retire 2028-09-30; Enterprise 2027-03-31."
  note "This module still provisions it, and it is fully supported until then."
  note ""
  note "The successor, Azure Managed Redis, is zone-redundant by default and costs"
  note "materially less (about \$26/month against \$101 at 1 GB). If your deployment"
  note "is expected to run past 2028, plan the migration — and do NOT buy the"
  note "Premium tier for zone redundancy, because the successor includes it."
  note "See AZURE_COST_SHAPES.md for the verified comparison."
}

# ---------------------------------------------------------------------------
# 4. Generate, plan, apply
# ---------------------------------------------------------------------------
module_path() {
  case "${TIER}" in
    single)    printf '%s-%s-single' "$PRODUCT" "$CLOUD" ;;
    ha)        printf '%s-%s-ha' "$PRODUCT" "$CLOUD" ;;
    autoscale) printf '%s-%s-autoscale' "$PRODUCT" "$CLOUD" ;;
  esac
}

write_config() {
  mkdir -p "$WORKDIR"
  local mod; mod="$(module_path)"
  local pinned="${MARKETPLACE_LATEST:-}"

  say ""
  head2 "Writing configuration to ${WORKDIR}"

  # Pin the image version when we managed to discover one. An unpinned
  # "latest" makes a patch invisible to terraform plan.
  local image_pin=""
  if [ "$CLOUD" = azure ] && [ -n "$pinned" ]; then
    image_pin="marketplace_image_version = \"${pinned}\""
  fi

  cat > "${WORKDIR}/main.tf" <<EOF
# Generated by quickstart/deploy.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Review this before applying — it is yours to edit and keep in version control.

terraform {
  required_version = ">= 1.5.0"
}

module "hailbytes" {
  source = "${REPO_GIT}//modules/${mod}"

$(printf '  %s\n' "${SETTINGS[@]}")
${image_pin:+  $image_pin}
}

output "endpoint" {
  description = "Browse here once apply completes."
  value       = try(module.hailbytes.load_balancer_public_ip, try(module.hailbytes.alb_dns_name, try(module.hailbytes.public_ip, "see module outputs")))
}
EOF

  if [ "${DB_MODE:-}" = external ]; then
    cat > "${WORKDIR}/secrets.auto.tfvars" <<EOF
# Contains a database password. Do NOT commit this file.
external_db_password = "${EXT_DB_PASS}"
EOF
    chmod 600 "${WORKDIR}/secrets.auto.tfvars"
    printf 'secrets.auto.tfvars\n.terraform/\n*.tfstate*\n' > "${WORKDIR}/.gitignore"
    warn "Database password written to ${WORKDIR}/secrets.auto.tfvars (mode 600, gitignored)."
  fi

  ok "Wrote ${WORKDIR}/main.tf"
  say ""
  note "--- main.tf ---"
  sed 's/^/  /' "${WORKDIR}/main.tf"
}

run_plan_and_apply() {
  cd "$WORKDIR"
  head2 "terraform init"
  terraform init -input=false -upgrade

  head2 "terraform plan"
  terraform plan -input=false -out=hailbytes.tfplan

  say ""
  cost_warning "This is the last step before resources are created." \
    "Everything above is what will be built. The HailBytes software bills" \
    "through your cloud Marketplace at \$${METER_PER_VCPU_HOUR}/vCPU-hour, and cloud" \
    "infrastructure bills separately from your cloud provider." \
    "" \
    "Nothing has been created yet. Answering no costs you nothing."

  local reply
  read -r -p "$(printf '%sType APPLY to create these resources: %s' "$CYN" "$R")" reply || true
  if [ "$reply" != "APPLY" ]; then
    say ""
    ok "Nothing applied. Your configuration is in ${WORKDIR} — run 'terraform apply hailbytes.tfplan' there when you are ready."
    exit 0
  fi
  terraform apply -input=false hailbytes.tfplan

  head2 "Done"
  terraform output || true
  say ""
  # The URL is worth spelling out. SAT serves its admin UI on 3333, so on the
  # single-VM tier -- where there is no load balancer to translate 443 to it --
  # an operator who visits the bare IP gets a connection refused and reasonably
  # concludes the deployment failed.
  local admin_url_port=""
  if [ "$PRODUCT" = sat ] && [ "$TIER" = single ]; then
    admin_url_port=":3333"
  fi
  say ""
  note "Admin UI:  https://<endpoint from above>${admin_url_port}"
  note "  The certificate is self-signed unless you fronted this with a gateway,"
  note "  so expect a browser warning on the first visit."
  say ""
  note "Next steps:"
  note "  • Retrieve the initial admin password from the VM's serial console output,"
  note "    or from ~/hailbytes-sat-initial-credentials.txt on the instance."
  note "  • Read docs/AZURE_PATCHING_AND_MIGRATION.md (or docs/PATCHING_AND_MIGRATION.md"
  note "    on AWS) before your first image update."
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  say ""
  say "${B}HailBytes guided deployment${R}"
  note "Deploys HailBytes SAT or ASM into your own cloud account from the published"
  note "Marketplace image, using the open-source Terraform modules in ${REPO_GIT}."
  note "Nothing is created until you confirm a plan."

  CLOUD="$(detect_cloud)"
  if [ "$CLOUD" = unknown ]; then
    local c
    c="$(choose "Which cloud are you deploying to?" "Azure|azure" "AWS|aws")"
    CLOUD="${c##*|}"
  else
    say ""
    ok "Detected ${CLOUD} Cloud Shell"
  fi

  head2 "Prerequisites"
  check_prereqs "$CLOUD"

  pick_product
  pick_tier
  pick_region
  check_marketplace_subscription "$CLOUD" "$PRODUCT" "$REGION"
  pick_db_mode
  pick_scale_knobs
  pick_frontend
  pick_key_vault_name
  warn_about_egress
  warn_about_redis_retirement

  # Assemble the module settings. Kept as an array so main.tf stays readable.
  SETTINGS=()
  if [ "$CLOUD" = azure ]; then
    SETTINGS+=("location = \"${REGION}\"")
    SETTINGS+=("resource_group_name = \"$(ask "Resource group name (must already exist)" "rg-hailbytes-${PRODUCT}")\"")
    SETTINGS+=("admin_username = \"$(ask "Admin username" "hbadmin")\"")
    local keyfile; keyfile="$(ask "Path to your SSH public key" "$HOME/.ssh/id_rsa.pub")"
    [ -f "$keyfile" ] || die "No SSH public key at ${keyfile}. Generate one with: ssh-keygen -t ed25519"
    SETTINGS+=("ssh_public_key = file(\"${keyfile}\")")
    SETTINGS+=("allowed_cidrs = [\"$(ask "CIDR allowed to reach the admin UI" "$(curl -fsS -m 5 ifconfig.me 2>/dev/null || echo 10.0.0.0/8)/32")\"]")
    note "You must also supply the network inputs (vm_subnet_id, lb_subnet_id,"
    note "db_delegated_subnet_id, private_dns_zone_id). quickstart/azure-ha shows a"
    note "root config that creates them with modules/network/azure."
    [ "${APPGW:-false}" = true ] && SETTINGS+=("enable_application_gateway = true")
    [ -n "${KEY_VAULT_NAME:-}" ] && SETTINGS+=("key_vault_name = \"${KEY_VAULT_NAME}\"")
  else
    SETTINGS+=("# vpc_id, public_subnet_ids, private_subnet_ids and acm_certificate_arn")
    SETTINGS+=("# are required — see modules/network/aws to create the network.")
    SETTINGS+=("allowed_cidrs = [\"$(ask "CIDR allowed to reach the admin UI" "$(curl -fsS -m 5 ifconfig.me 2>/dev/null || echo 10.0.0.0/8)/32")\"]")
  fi
  [ -n "${DB_MODE:-}" ] && SETTINGS+=("db_mode = \"${DB_MODE}\"")
  if [ "${DB_MODE:-}" = external ]; then
    SETTINGS+=("external_db_host = \"${EXT_DB_HOST}\"")
    SETTINGS+=("external_db_port = ${EXT_DB_PORT}")
    SETTINGS+=("external_db_name = \"${EXT_DB_NAME}\"")
    SETTINGS+=("external_db_username = \"${EXT_DB_USER}\"")
    SETTINGS+=("# external_db_password comes from secrets.auto.tfvars")
  fi
  if [ "$TIER" = autoscale ]; then
    if [ "$CLOUD" = azure ]; then
      SETTINGS+=("vmss_min_count = ${MIN_COUNT}" "vmss_default_count = ${MIN_COUNT}" "vmss_max_count = ${MAX_COUNT}")
    else
      SETTINGS+=("asg_min_size = ${MIN_COUNT}" "asg_desired_capacity = ${MIN_COUNT}" "asg_max_size = ${MAX_COUNT}")
    fi
    [ -n "${REPLICAS:-}" ] && SETTINGS+=("db_replica_count = ${REPLICAS}")
  fi

  write_config

  say ""
  if ! confirm "Run terraform init and plan now?"; then
    ok "Configuration written to ${WORKDIR}. Run terraform there when ready."
    exit 0
  fi
  run_plan_and_apply
}

# Sourceable for testing: `HAILBYTES_WIZARD_LIB=1 . deploy.sh` defines the
# functions without running the wizard, which is how quickstart/tests/ exercises
# the pure logic (cloud detection, module-path mapping, cost-warning rendering)
# in CI without a Cloud Shell.
if [ -z "${HAILBYTES_WIZARD_LIB:-}" ]; then
  main "$@"
fi
