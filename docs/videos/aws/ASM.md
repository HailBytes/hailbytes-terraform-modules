# AWS, HailBytes ASM cut: what changes per chapter

The ASM series has the same four chapters and numbering as SAT
([SCRIPT.md](SCRIPT.md)). Its specs (`specs/aws-asm-NN-*.yaml`) are copies of
the SAT specs with the changes below. Everything not listed is identical.

**Never show ASM single sign-on.** ASM saves OIDC and SAML settings but has no
sign-in flow that uses them yet.

## Chapter 1: Subscribe and run the preflight

- The ASM listing: https://aws.amazon.com/marketplace/pp/prodview-66d5bswmbtfhs.
  The preflight already checks both listings, so its output is unchanged.

## Chapter 2: Deploy

- **Tier.** HA and autoscale need an ASM image with cluster mode
  (HailBytes/hailbytes-asm#1734 onward). Until the listing carries it, the ASM
  cut deploys **single**: `quickstart/aws-asm-single`, preflight `single`
  (no service-linked roles, no Elastic IPs). Single has a public IP, which AWS
  reassigns if the instance is stopped and started.
- **Settings.** No `phish_allowed_cidrs`.
- **Verify.** `api/ready` instead of `api/health`. `initial_credentials_command`
  reads the password off the instance through SSM Run Command. An instance
  takes a few minutes after boot to register with SSM; if it says it is not
  ready, wait and re-run.
- **Sizing.** `m6i.2xlarge` by default: 8 metered vCPUs on single.

## Chapter 3: DNS, a certificate and operator access

- **Single** has no load balancer: point an A record at the public IP, and
  skip the ACM steps. Re-cut with ACM once the HA tier is used.
- Replace the mail-delivery card with **LDAP / AD**: Settings, Identity &
  Access, LDAP / AD. The instance needs a network path to the directory.
- SCIM: ASM authenticates SCIM with an `X-API-Key` header. Show it only with an
  identity provider that can send a custom header.

## Chapter 4: Tear down

- Export with `Authorization: Token <key>`.
- Single has no deletion-protection apply and no RDS. Its backup bucket is
  still Object-Locked: empty it the same way.
