#!/usr/bin/env bash
# HailBytes SAT on Azure (single-VM tier) quickstart for Azure Cloud Shell.
#
# The fallback path: one VM with PostgreSQL on board. No load balancer, no
# Flexible Server, no redundancy -- a reboot is an outage and the VM holds the
# only copy of your campaign history.
#
# Paste into Cloud Shell (bash) at https://shell.azure.com and run:
#
#   curl -fsSL https://raw.githubusercontent.com/hailbytes/hailbytes-terraform-modules/main/quickstart/azure-single/cloudshell.sh | bash
#
# Or clone the repo and run ./cloudshell.sh from this directory.
#
# Prerequisite: an active subscription to the HailBytes SAT listing on Azure
# Marketplace. The Terraform module accepts the image terms for you, but the
# offer itself must be purchasable from your subscription:
#   https://marketplace.microsoft.com/en-us/product/virtual-machines/lcmcon1687976613543.gophish-phishing-simulator
#
# Overridable environment variables:
#   HB_CUSTOMER        MSSPs: short client name, e.g. acme. Gives the client its
#                      own clone, resource names, tags and state key, so running
#                      this again for the next client cannot touch this one.
#   HB_RESOURCE_GROUP  (default rg-hailbytes-sat-single, or rg-<customer>-sat-prod)
#   HB_LOCATION        (default northeurope)
#   HB_ALLOWED_CIDR    (default: your current egress IP /32)
#   HB_SSH_KEY_FILE    (default ~/.ssh/id_ed25519.pub, generated if absent)

set -euo pipefail

REPO_URL="https://github.com/hailbytes/hailbytes-terraform-modules"
RG="${HB_RESOURCE_GROUP:-}"
CUSTOMER="${HB_CUSTOMER:-}"
if [[ -n "$CUSTOMER" && ! "$CUSTOMER" =~ ^[a-z][a-z0-9-]{1,15}$ ]]; then
  echo "HB_CUSTOMER must be 2-16 characters: lowercase letters, digits and hyphens, starting with a letter." >&2
  exit 2
fi
LOCATION="${HB_LOCATION:-northeurope}"

echo "==> Checking Azure CLI login"
az account show --query '{subscription:name, id:id}' -o table

echo "==> Checking Terraform (preinstalled in Cloud Shell)"
terraform version | head -1

if [[ -z "${HB_ALLOWED_CIDR:-}" ]]; then
  MY_IP="$(curl -fsS https://api.ipify.org)"
  HB_ALLOWED_CIDR="${MY_IP}/32"
  echo "==> No HB_ALLOWED_CIDR set; defaulting admin-UI access to your current egress IP: ${HB_ALLOWED_CIDR}"
  echo "    This tier puts a public IP on the VM itself, so this list is the"
  echo "    only thing in front of the admin UI. Widen it deliberately."
fi

SSH_KEY_FILE="${HB_SSH_KEY_FILE:-$HOME/.ssh/id_ed25519.pub}"
if [[ ! -f "$SSH_KEY_FILE" ]]; then
  echo "==> No SSH key at ${SSH_KEY_FILE}; generating one"
  ssh-keygen -t ed25519 -N "" -f "${SSH_KEY_FILE%.pub}"
fi
SSH_KEY="$(cat "$SSH_KEY_FILE")"

if [[ ! -f main.tf ]]; then
  # One clone per client: the working directory holds that client's tfvars,
  # backend.tf and .terraform, and sharing it would point the next client's
  # apply at this client's state.
  CLONE="$HOME/hailbytes-terraform-modules${CUSTOMER:+-$CUSTOMER}"
  if [[ ! -d "$CLONE" ]]; then
    echo "==> Cloning ${REPO_URL} into ${CLONE}"
    git clone --depth 1 "$REPO_URL" "$CLONE"
  fi
  cd "$CLONE/quickstart/azure-single"
fi

echo "==> Writing terraform.tfvars"
cat > terraform.tfvars <<EOF
location            = "${LOCATION}"
allowed_cidrs       = ["${HB_ALLOWED_CIDR}"]
ssh_public_key      = "${SSH_KEY}"
EOF
if [[ -n "$RG" ]]; then echo "resource_group_name = \"${RG}\"" >> terraform.tfvars; fi
if [[ -n "$CUSTOMER" ]]; then echo "customer            = \"${CUSTOMER}\"" >> terraform.tfvars; fi

# Subscription prerequisites. main.tf turns the azurerm registration sweep off
# on purpose, so the providers this stack needs must be registered explicitly --
# otherwise the first apply fails with "API version ... was not found for
# Microsoft.X", which points at the API version rather than the cause.
# Idempotent; safe to re-run.
PREFLIGHT="$(dirname "$0")/../preflight-azure.sh"
if [[ -x "$PREFLIGHT" ]]; then
  echo "==> Subscription preflight (resource providers, marketplace terms)"
  # With a customer set, main.tf does not accept the Marketplace terms (they are
  # per subscription, and a Terraform-owned agreement is cancelled for every
  # deployment when any one is destroyed), so accept them here, once.
  "$PREFLIGHT" single --location "$LOCATION" ${CUSTOMER:+--accept-terms} || {
    echo "Preflight failed. Fix the reported items before applying -- an apply" >&2
    echo "against an unprepared subscription fails late and leaves partial state." >&2
    exit 1
  }
else
  echo "==> WARNING: preflight-azure.sh not found next to this script."
  echo "    Register the required providers manually before applying; see"
  echo "    SECURITY-DEFAULTS.md, \"Subscription prerequisites\"."
fi

echo "==> terraform init"
terraform init -input=false

echo "==> terraform apply (review the plan, then confirm)"
terraform apply

echo ""
echo "Done. Admin UI: $(terraform output -raw console_url 2>/dev/null || echo '(see terraform output console_url)')"
echo ""
echo "Retrieve the initial admin password with:"
terraform output -raw initial_credentials_command 2>/dev/null || true
echo ""
echo "The admin server uses a self-signed certificate on first boot, so your"
echo "browser will warn. Change the admin password at first login."
