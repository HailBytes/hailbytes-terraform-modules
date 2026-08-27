#!/usr/bin/env bash
#
# Key Vault maintenance for a HailBytes deployment whose apply ran as a SERVICE
# PRINCIPAL.
#
# WHY THIS EXISTS
#
# The module grants Key Vault Secrets Officer to whichever identity ran
# `terraform apply` (ha-hot-hot/azure, azurerm_role_assignment.kv_secret_writer).
# Deploy as a person and that person can read and rotate the deployment's
# secrets. Deploy as a service principal and ONLY the service principal can, so
# at the moment an operator needs the database password they have to go and
# borrow the deployment credential. That is the wrong thing to be doing under
# pressure.
#
# The durable fix is key_vault_reader_principal_ids on the module: grant your
# operators, or better a group, at deploy time. This script is for the cases
# terraform does not cover -- reading a secret now, granting access now, and
# rotating the session keys.
#
# WHAT LIVES IN THE VAULT
#
#   hailbytes-admin-initial-password  first-boot admin password. Once someone
#                                     has logged in and changed it, this is
#                                     history rather than a live credential.
#   hailbytes-db-password             PostgreSQL password the app authenticates
#                                     with.
#   hailbytes-session-keys            gorilla/securecookie hash and encryption
#                                     keys, shared by both nodes.
#   hailbytes-redis-*                 Redis connection secret, when Redis is on.
#
# Usage:
#   ./keyvault-maintenance.sh list        --vault <name>
#   ./keyvault-maintenance.sh get         --vault <name> --secret <name>
#   ./keyvault-maintenance.sh grant       --vault <name> --principal <object-id>
#   ./keyvault-maintenance.sh rotate-session-keys --vault <name>
#
# Run it as whoever currently holds the vault. If that is the service principal:
#   az login --service-principal -u "$ARM_CLIENT_ID" -p "$ARM_CLIENT_SECRET" \
#            --tenant "$ARM_TENANT_ID"

set -euo pipefail

CMD="${1:-}"; shift || true
VAULT=""; SECRET=""; PRINCIPAL=""; ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --vault)     VAULT="${2:?--vault needs a name}"; shift ;;
        --secret)    SECRET="${2:?--secret needs a name}"; shift ;;
        --principal) PRINCIPAL="${2:?--principal needs an object id}"; shift ;;
        --yes)       ASSUME_YES=1 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

need_vault() {
    [ -n "$VAULT" ] || { echo "--vault is required" >&2; exit 2; }
}

case "$CMD" in
    list)
        need_vault
        echo "Secrets in ${VAULT}:"
        az keyvault secret list --vault-name "$VAULT" \
            --query "[].{name:name, updated:attributes.updated}" -o table
        ;;

    get)
        need_vault
        [ -n "$SECRET" ] || { echo "--secret is required" >&2; exit 2; }
        # No echo to the terminal beyond the value itself, so it can be piped
        # without a header to strip.
        az keyvault secret show --vault-name "$VAULT" --name "$SECRET" \
            --query value -o tsv
        ;;

    grant)
        need_vault
        [ -n "$PRINCIPAL" ] || { echo "--principal is required (an Entra object id)" >&2; exit 2; }
        scope="$(az keyvault show --name "$VAULT" --query id -o tsv)"
        # Secrets User, not Officer: read, not rewrite. An operator who needs to
        # READ a credential during an incident does not need to be able to
        # replace it, and Officer on a shared vault is how session keys get
        # overwritten by accident.
        az role assignment create \
            --role "Key Vault Secrets User" \
            --assignee-object-id "$PRINCIPAL" \
            --assignee-principal-type Group \
            --scope "$scope" >/dev/null 2>&1 \
        || az role assignment create \
            --role "Key Vault Secrets User" \
            --assignee-object-id "$PRINCIPAL" \
            --assignee-principal-type User \
            --scope "$scope" >/dev/null
        echo "Granted Key Vault Secrets User on ${VAULT} to ${PRINCIPAL}."
        echo
        echo "This is an out-of-band grant. Terraform does not know about it, and"
        echo "a later apply will not remove it but will not recreate it either if"
        echo "the vault is replaced. Add the id to key_vault_reader_principal_ids"
        echo "so it survives."
        ;;

    rotate-session-keys)
        need_vault
        echo "Rotating hailbytes-session-keys on ${VAULT}."
        echo
        echo "READ THIS FIRST. The session keys are what both nodes use to sign and"
        echo "encrypt session cookies. Replacing them does not expire sessions"
        echo "gracefully: every cookie minted under the old keys becomes"
        echo "undecryptable, so EVERY LOGGED-IN USER IS SIGNED OUT the moment the"
        echo "app processes the new value. Campaigns in flight are unaffected."
        echo
        echo "The nodes read this at boot, so the rotation is not live until both"
        echo "have restarted. Restart them one at a time, not together, or the"
        echo "deployment is briefly down rather than degraded."
        echo
        if [ "$ASSUME_YES" -ne 1 ]; then
            printf "Type ROTATE to continue: "
            read -r reply
            [ "$reply" = "ROTATE" ] || { echo "Aborted."; exit 1; }
        fi
        # 64 bytes: a 32-byte hash key and a 32-byte encryption key, the sizes
        # gorilla/securecookie expects, hex-encoded as the app reads them.
        new="$(openssl rand -hex 64)"
        az keyvault secret set --vault-name "$VAULT" \
            --name hailbytes-session-keys --value "$new" >/dev/null
        echo "Done. Now restart the application nodes ONE AT A TIME:"
        echo "  az vm restart --resource-group <rg> --name <node-1>   # wait for healthy"
        echo "  az vm restart --resource-group <rg> --name <node-2>"
        ;;

    *)
        sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
