#!/usr/bin/env bash
# HailBytes SAT on Azure (HA tier) quickstart for Azure Cloud Shell.
#
# Paste into Cloud Shell (bash) at https://shell.azure.com and run:
#
#   curl -fsSL https://raw.githubusercontent.com/hailbytes/hailbytes-terraform-modules/main/quickstart/azure-ha/cloudshell.sh | bash
#
# Or clone the repo and run ./cloudshell.sh from this directory.
#
# Prerequisite: an active subscription to the HailBytes SAT listing on
# Azure Marketplace. The Terraform module accepts the image terms for
# you, but the marketplace offer itself must be purchasable from your
# subscription:
#   https://marketplace.microsoft.com/en-us/product/virtual-machines/lcmcon1687976613543.gophish-phishing-simulator
#
# Overridable environment variables:
#   HB_RESOURCE_GROUP  (default rg-hailbytes-sat-prod)
#   HB_LOCATION        (default northeurope)
#   HB_ALLOWED_CIDR    (default: your current egress IP /32)
#   HB_SSH_KEY_FILE    (default ~/.ssh/id_ed25519.pub, generated if absent)

set -euo pipefail

REPO_URL="https://github.com/hailbytes/hailbytes-terraform-modules"
RG="${HB_RESOURCE_GROUP:-rg-hailbytes-sat-prod}"
LOCATION="${HB_LOCATION:-northeurope}"

echo "==> Checking Azure CLI login"
az account show --query '{subscription:name, id:id}' -o table

echo "==> Checking Terraform (preinstalled in Cloud Shell)"
terraform version | head -1

if [[ -z "${HB_ALLOWED_CIDR:-}" ]]; then
  MY_IP="$(curl -fsS https://api.ipify.org)"
  HB_ALLOWED_CIDR="${MY_IP}/32"
  echo "==> No HB_ALLOWED_CIDR set; defaulting admin-UI access to your current egress IP: ${HB_ALLOWED_CIDR}"
fi

SSH_KEY_FILE="${HB_SSH_KEY_FILE:-$HOME/.ssh/id_ed25519.pub}"
if [[ ! -f "$SSH_KEY_FILE" ]]; then
  echo "==> No SSH key at ${SSH_KEY_FILE}; generating one"
  ssh-keygen -t ed25519 -N "" -f "${SSH_KEY_FILE%.pub}"
fi
SSH_KEY="$(cat "$SSH_KEY_FILE")"

if [[ ! -f main.tf ]]; then
  echo "==> Cloning ${REPO_URL}"
  git clone --depth 1 "$REPO_URL" "$HOME/hailbytes-terraform-modules"
  cd "$HOME/hailbytes-terraform-modules/quickstart/azure-ha"
fi

echo "==> Writing terraform.tfvars"
cat > terraform.tfvars <<EOF
resource_group_name = "${RG}"
location            = "${LOCATION}"
allowed_cidrs       = ["${HB_ALLOWED_CIDR}"]
ssh_public_key      = "${SSH_KEY}"
EOF

echo "==> terraform init"
terraform init -input=false

echo "==> terraform apply (review the plan, then confirm)"
terraform apply

echo ""
echo "Done. Admin UI: https://\$(terraform output -raw load_balancer_public_ip)/"
echo "Note: the default load balancer passes TLS through to the VMs'"
echo "self-signed certificates, so your browser will warn. For a trusted"
echo "certificate in production, see 'TLS termination' in"
echo "modules/ha-hot-hot/azure/README.md (enable_application_gateway)."
