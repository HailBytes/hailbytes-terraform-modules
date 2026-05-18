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
| In-transit — LB to VM | TLS terminated at LB; HTTP to VM over private subnet only | `backend_tls_enabled = true` for end-to-end TLS |
| In-transit — VM to DB | TLS required (`rds.force_ssl=1`, Azure equivalent) | `require_db_tls = true` (default) |

## Network

- **Security groups / NSGs** default to **deny all** inbound. Required ports (443 for the LB, 5432 between VMs and DB) are opened only to the CIDRs you pass in `allowed_cidrs`. Wide-open `0.0.0.0/0` requires `allow_internet_ingress = true` and emits a deprecation warning.
- **SSH** is **not** exposed by default. For break-glass access, prefer **AWS SSM Session Manager** (IAM-gated) or **Azure Bastion**. Modules wire these up when `enable_management_access = true`.
- **IMDSv2** is required on every EC2 launch (`http_tokens = "required"`).
- **Public IPs** are off by default. The LB has a public DNS name; the VMs sit in private subnets.
- VMs are tagged for AWS Inspector / Azure Defender for Servers auto-enrollment when those services are enabled at the account level.

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

- VPC Flow Logs / Azure NSG Flow Logs are enabled by default (`enable_flow_logs = true`).
- LB access logs land in an S3 bucket / Storage Account with versioning and a 90-day lifecycle policy (`access_log_retention_days = 90`).
- CloudTrail / Azure Activity Log are **not** managed by these modules — those are account-level concerns and should be owned by your landing-zone tooling.

## Patching

The HailBytes marketplace image is the source of truth for in-image patches. When HailBytes publishes a new image version, you:

1. Pull the latest module version (or bump the pinned image version in your tfvars).
2. `terraform plan` shows the launch template / VMSS image reference changing.
3. `terraform apply` triggers instance refresh (ASG) or rolling upgrade (VMSS) — zero-downtime in `ha-hot-hot` and `unlimited-scale` tiers, ~2 min downtime in `single-vm`.

Do not run `apt`/`yum` updates inside the running VM. The image is immutable; replace it.

## Reporting vulnerabilities

Security issues in these Terraform modules: open a private security advisory in this repo's GitHub Security tab.

Security issues in the HailBytes software itself (inside the marketplace VM image): see `SECURITY.md` in the relevant product repo (`hailbytes-asm`, `hailbytes-sat`).
