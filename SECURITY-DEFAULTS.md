# Module Security Defaults

These modules ship with security-conservative defaults. You should have to explicitly opt *out* of safety, not opt in.

## Encryption

| Surface | Default | Knob |
|---|---|---|
| Root volume / OS disk | Encrypted with cloud-managed CMK | `enable_customer_managed_key = true` switches to KMS / Key Vault key created by the module |
| Data volume / data disk | Encrypted | Same as above |
| RDS / Azure DB for PostgreSQL storage | Encrypted | Customer-managed KMS/Key Vault key supported |
| RDS / Azure DB backups | Encrypted | n/a (forced on) |
| In-transit — client to LB | TLS 1.2+ required | `min_tls_version` (default `TLS_1_2`) |
| In-transit — LB to VM | AWS: TLS to the instance on 443. Azure: the Standard LB is L4 passthrough; with `enable_application_gateway = true` the gateway terminates TLS and the backend hop defaults to HTTP inside the customer vnet | Azure: `appgw_backend_protocol = "Https"` for end-to-end TLS — requires `appgw_backend_root_cert_pem` and `appgw_backend_host_header`, because App Gateway v2 validates the backend certificate |
| In-transit — VM to DB | TLS required (`rds.force_ssl=1`; `require_secure_transport=ON` on Azure) | Forced on. In `db_mode = "external"`, `external_db_sslmode` accepts only `require`/`verify-ca`/`verify-full` |

## Network

- **Security groups / NSGs** default to **deny all** inbound. Required ports are opened only to the CIDRs you pass in `allowed_cidrs`: the public frontend (443, plus 80 for the SAT phishing/landing surface), the application port behind it (SAT 3333, ASM 443 — see `admin_port` / `phish_port`), and 5432 between VMs and the database. On the `single-vm` tier there is no load balancer, so the application port *is* the public frontend. Wide-open `0.0.0.0/0` requires `allow_internet_ingress = true` and emits a deprecation warning.
- **SSH** is **not** exposed by default. For break-glass access, `enable_management_access = true` wires up **AWS SSM Session Manager** (IAM-gated, via `AmazonSSMManagedInstanceCore`) on AWS, and the **`AADSSHLoginForLinux`** extension on Azure — Entra-authenticated, RBAC-gated SSH through `az ssh vm` with no public IP. Azure Bastion is *not* provisioned by the modules; the extension is the lighter-weight equivalent, and operators still need the `Virtual Machine Administrator Login` or `Virtual Machine User Login` role granted to them.
- **IMDSv2** is required on every EC2 launch (`http_tokens = "required"`).
- **Public IPs** are off by default. The LB has a public DNS name; the VMs sit in private subnets.
- VMs are tagged for AWS Inspector / Azure Defender for Servers auto-enrollment when those services are enabled at the account level.

## Cloud account prerequisites

Both clouds gate a class of first-time resource creation behind an
account-level activation step that a least-privilege deploying identity may
not be allowed to perform. Left unchecked, it fails LATE — mid-apply, after
some resources already exist — with an error that names an API version or an
IAM action rather than the real cause. `quickstart/deploy.sh` checks both
(`check_cloud_prerequisites`, run right after you pick a tier) and offers to
fix what it can; `quickstart/preflight-azure.sh` / `quickstart/preflight-aws.sh`
do the same checks standalone, for anyone not using the wizard.

### Azure: resource providers

The Azure modules set `resource_provider_registrations = "none"` on the `azurerm`
provider. This is deliberate, and it changes what your subscription must have in place
before the first apply.

Terraform's default (`"legacy"`) attempts to register roughly seventy resource providers
on every apply — including many nothing here touches, such as `Microsoft.BotService`,
`Microsoft.HealthcareApis` and `Microsoft.DataFactory`. Registration is a
**subscription-scoped write** (`*/register/action`). A service principal scoped to a
resource group, or any least-privilege operator role, does not hold it, so the apply dies
on a wall of `AuthorizationFailed` 403s before creating a single resource. Granting
subscription-wide write purely to satisfy a registration sweep is the wrong trade.

With registration off, a subscription **owner** registers the providers the modules
actually use, once per subscription:

```bash
for rp in Microsoft.Cache Microsoft.Compute Microsoft.DBforPostgreSQL Microsoft.Insights \
          Microsoft.KeyVault Microsoft.ManagedIdentity Microsoft.MarketplaceOrdering \
          Microsoft.Network Microsoft.OperationalInsights Microsoft.Storage; do
  az provider register --namespace "$rp" --wait
done
```

`Microsoft.Cache` is in that list because the HA tier needs it by DEFAULT — this
is not the optional extra it used to be documented as. `enable_managed_redis`
defaults to `true` and `redis_endpoint_override` defaults to `null`, so a default
HA apply creates an Azure Cache for Redis. (The variable is
`enable_managed_redis`; there is no `enable_redis`.) Set it to `false` to skip
both the cache and the namespace — Redis is a performance optimisation, not an HA
requirement, since shared session keys make the default cookie store work across
nodes (hailbytes-sat#907).

The single-VM tier needs neither `Microsoft.Cache` nor `Microsoft.DBforPostgreSQL`:
it runs PostgreSQL on the VM and provisions no cache. `Microsoft.Network` already
covers Application Gateway on both tiers.

`quickstart/preflight-azure.sh {ha|single}` checks and registers this whole list
for you, and is idempotent.

Most subscriptions that have ever deployed a VM already have `Microsoft.Compute`,
`Microsoft.Network` and `Microsoft.Storage` registered; `Microsoft.DBforPostgreSQL` is the
one most often missing. Check before you plan:

```bash
az provider show --namespace Microsoft.DBforPostgreSQL --query registrationState -o tsv
```

If a required provider is unregistered, the failure surfaces from whichever resource is
created first and reads as `API version 20XX-XX-XX was not found for Microsoft.Foo` — a
message that points at the API version rather than the real cause. The CI smoke in
`hailbytes-sat` asserts registration state up front for exactly this reason, and names the
missing provider.

### AWS: service-linked roles

AWS has no direct equivalent of resource-provider registration, but RDS,
ElastiCache and Elastic Load Balancing each depend on a one-time,
account-level **service-linked role** — an IAM role AWS itself uses to manage
the service on your behalf. AWS normally creates the role for you, silently,
the first time you touch that service — PROVIDED the calling identity holds
`iam:CreateServiceLinkedRole`. A least-privilege deploy role scoped down to
"create EC2/RDS/ElastiCache resources" often does **not** include that action,
because it reads as an IAM-admin permission rather than an
EC2/RDS/ElastiCache one.

Without the role, apply does not fail at the start the way an unregistered
Azure provider does — it fails when Terraform creates the FIRST resource of
that kind (an `aws_db_instance`, an `aws_elasticache_replication_group`, or an
`aws_lb`), with an `AccessDenied` error naming the missing IAM action, not
"you are missing a service-linked role".

The single-VM tier needs none of these roles: it has no RDS, no ElastiCache
and no load balancer. The HA and autoscale tiers need `AWSServiceRoleForRDS`,
`AWSServiceRoleForElastiCache` and `AWSServiceRoleForElasticLoadBalancing`;
autoscale additionally needs `AWSServiceRoleForAutoScaling`. Check whether a
role already exists (existence, not just permission, since most accounts that
have ever created a load balancer already have the ELB role):

```bash
aws iam list-roles --path-prefix /aws-service-role/rds.amazonaws.com/ --query 'Roles[0].RoleName' --output text
```

`quickstart/preflight-aws.sh {single|ha|autoscale}` checks and creates this
whole list for you, and is idempotent — creating a service-linked role creates
no billable resource.

Unlike Azure's marketplace-terms CLI action (`az vm image terms accept`), AWS
Marketplace subscription has no CLI equivalent — it is a console-only action
(the listing's "Continue to Subscribe" button), so no script can complete that
step on your behalf.

## IAM / RBAC

- Each module creates a **least-privilege instance profile / managed identity** scoped to:
  - Read its own marketplace product code (for subscription verification)
  - Read/write its own CloudWatch / Azure Monitor namespace
  - Read its own KMS / Key Vault keys
  - Read its own secrets (DB connection string) from Secrets Manager / Key Vault
  - Nothing else
- No wildcard `*` resources in attached policies.
- No long-lived access keys. Instance profiles / managed identities only.

## Secrets

- DB master passwords are generated via `random_password` (32 chars, full symbol set) and stored in **AWS Secrets Manager** or **Azure Key Vault**, never in plaintext outputs or Terraform state diff logs (`sensitive = true`).
- Customer-supplied admin credentials are accepted only via `sensitive` variables and are pushed to Secrets Manager / Key Vault on first apply, not stored in state alongside the resources.

## Logging & audit

- **AWS:** VPC Flow Logs are enabled by default (`enable_flow_logs = true`), to a KMS-encrypted CloudWatch log group. ALB access logs are opt-in (`enable_alb_access_logging`) to a versioned, lifecycled S3 bucket.
- **Azure:** VNet flow logs are **opt-in** (`enable_flow_logs = true` on `network/azure`), to a Storage Account with shared-key auth disabled, retained **180 days** (`flow_log_retention_days`). Retention must exceed 90 days to satisfy CKV_AZURE_12 and is validated in the variable; it drives Storage Account cost roughly linearly, so lower it only alongside a documented waiver. Implemented as *VNet* flow logs rather than NSG flow logs, since NSG flow logs are being retired.

  **They defaulted to on and no longer do — this is a real reduction in what ships by default, recorded here rather than glossed.** That Storage Account is created with both shared keys and public network access disabled, and the `azurerm` provider reads its queue service properties over the storage *data plane*. An apply run from anywhere outside the VNet — Cloud Shell, a laptop, CI — therefore failed with `403 KeyBasedAuthenticationNotPermitted`, on refresh as well as create. Because it defaulted on, **every** caller composing `network/azure` hit an apply that could not succeed, so the effective default was not "flow logs on" but "deployment broken". Turning it off is what makes the documented posture and the observable behaviour agree again. Enabling it needs either a network path to that account's data plane or a provider that reads those properties over ARM.
- **Azure:** diagnostic settings for the load balancer, database, cache and (when enabled) Application Gateway go to a Log Analytics workspace by default (`enable_diagnostics = true`); pass `log_analytics_workspace_id` to use your landing zone's central workspace instead. Note a Standard Load Balancer is Layer 4 and has **no** request-level access log — `ApplicationGatewayAccessLog` is the closest analogue of AWS ALB access logs, and it only exists when `enable_application_gateway = true`.
- CloudTrail / Azure Activity Log are **not** managed by these modules — those are account-level concerns and should be owned by your landing-zone tooling.

## Patching

The HailBytes marketplace image is the source of truth for in-image patches. When HailBytes publishes a new image version, you:

1. Pull the latest module version (or bump the pinned image version in your tfvars).
2. **Run the pre-patch backup** via the SSM Run Command (AWS) or Azure Run Command document the module provisions. This produces a tamper-evident bundle in the immutable backup bucket / container — DB dump + uploads + manifest with the encryption-key fingerprint stamped in.
3. `terraform plan` shows the launch template / VMSS image reference changing.
4. `terraform apply` triggers instance refresh (ASG) or rolling upgrade (VMSS) — zero-downtime in `ha-hot-hot` and `unlimited-scale` tiers, ~2 min downtime in `single-vm`. On AWS autoscale, CloudWatch tripwires (5xx-rate, unhealthy-host count) auto-rollback the refresh. On Azure autoscale, `automatic_instance_repair` + rolling-upgrade `max_unhealthy_*` pauses the upgrade.
5. Post-patch verify: curl `module.<name>.schema_version_endpoint` (the module emits this output) and confirm the encryption-key fingerprint hasn't drifted.

Do not run `apt`/`yum` updates inside the running VM. The image is immutable; replace it.

Full runbook with audit pointers (no HailBytes admin access, no phone-home, customer-initiated only): [docs/PATCHING_AND_MIGRATION.md](docs/PATCHING_AND_MIGRATION.md).

## Reporting vulnerabilities

Security issues in these Terraform modules: open a private security advisory in this repo's GitHub Security tab.

Security issues in the HailBytes software itself (inside the marketplace VM image): see `SECURITY.md` in the relevant product repo (`hailbytes-asm`, `hailbytes-sat`).
