# Azure, HailBytes ASM cut: what changes per chapter

The ASM series has the same five chapters and numbering as SAT
([SCRIPT.md](SCRIPT.md)). Its specs (`specs/azure-asm-NN-*.yaml`) are copies
of the SAT specs with the changes below. Everything not listed is identical.

**Never show ASM single sign-on.** ASM saves OIDC and SAML settings but has no
sign-in flow that uses them yet. The ASM cut shows LDAP / AD only (chapter 4).

## Chapter 1: Marketplace terms and programmatic deployment

- Offer `hardened_ubuntu_with_rengine` in place of `gophish-phishing-simulator`.
  Preflight: `preflight-azure.sh <tier> --product asm --location <region> --accept-terms`,
  and the `az vm image terms show` check uses the ASM offer.
- "Running both products?" card: reverse the order (asm first, then sat).

## Chapter 2: The deploying identity

- Same roles. The group example is "ASM Operators".
- The Key Vault consequence applies to the HA and autoscale tiers. The single-VM
  root has no Key Vault reader input.

## Chapter 3: Deploy

- **Tier.** HA and autoscale need an ASM image with cluster mode
  (HailBytes/hailbytes-asm#1734 onward). Until the Marketplace listing carries
  it, the ASM cut deploys **single VM**: `quickstart/azure-asm-single`, and the
  preflight runs with `single`. Re-cut on HA once the image ships, and check
  `/api/ready` on every node reports the same `database_id`.
- **Quota.** The single-VM default size is `Standard_D4s_v5`, which draws
  `standardDSv5Family`. That pool is often 0 in a subscription that has never
  asked for it. Show the preflight's quota section, and `vm_size` as the fix.
- **Wizard.** Answer `2` (ASM) at the product question. Single VM has no
  database question.
- **Settings.** No `phish_allowed_cidrs`: ASM has no phishing surface. Its
  console is on 443.
- **Verify.** `curl ... "${URL}api/ready"` instead of `api/health`.
  `initial_credentials_command` reads `DJANGO_SUPERUSER_PASSWORD` off the VM
  through Run Command, so allow for a slower answer.
- **Timings.** Single VM has no Flexible Server, so the apply is minutes, not
  30 to 45. Drop the standby card.

## Chapter 4: Entra ID: operator access and LDAP / AD

Retitle. Keep "1. Secrets" (HA only) and "2. Shell access"
(`enable_management_access` on `quickstart/azure-asm-ha`). Replace
"3. Single sign-on" and "4. Provisioning" with:

- **LDAP / AD.** Settings, Identity & Access, LDAP / AD: server URI, a service
  account bind DN and password, search base and filter, and the role a user gets
  on first sign-in. The VM has to reach the directory: a domain controller over
  your VPN or peering, or Entra Domain Services over LDAPS.
- **Not SCIM from Entra ID, yet.** ASM's SCIM endpoint authenticates with an
  `X-API-Key` header, and Entra's provisioning service can only send
  `Authorization: Bearer`. Leave SCIM out of the ASM cut until ASM accepts a
  bearer token.

## Chapter 5: Tear down

- The export takes the API key as `Authorization: Token <key>`, not `Bearer`.
- Sweep prefix `acme-asm-`. State key `clients/acme/asm-<tier>.tfstate`.
