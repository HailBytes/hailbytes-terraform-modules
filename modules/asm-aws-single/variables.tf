# Variables for ASM on AWS (single)
# Mirrors modules/single-vm/aws/variables.tf (without `product`,
# which is hardcoded by this wrapper).

variable "vpc_id" {
  description = "VPC to deploy into."
  type        = string
}

variable "subnet_id" {
  description = "Subnet to deploy the instance into. Must be in var.vpc_id."
  type        = string
}

variable "allowed_cidrs" {
  description = "CIDR blocks permitted to reach the VM on port 443. Use private CIDRs unless you also set allow_internet_ingress = true."
  type        = list(string)
}

variable "phish_allowed_cidrs" {
  description = "CIDRs permitted to reach the phishing/landing surface (SAT only; ASM has no such surface). Leave null to inherit allowed_cidrs, which is the historical behaviour and keeps existing deployments planning clean. Set it whenever the simulation targets are not inside the admin allow-list -- with one shared list, locking the console to an office range also locks every target out of the landing pages, and the campaign sends and then records no interactions. \"0.0.0.0/0\" is the usual value for a live simulation."
  type        = list(string)
  default     = null

  validation {
    condition     = alltrue([for c in coalesce(var.phish_allowed_cidrs, []) : can(cidrhost(c, 0))])
    error_message = "All phish_allowed_cidrs entries must be valid CIDR blocks (e.g. \"0.0.0.0/0\")."
  }
}

variable "environment" {
  description = "Environment tag (e.g. dev, staging, prod). Used in resource names and tags."
  type        = string
  default     = "dev"
}

variable "name_prefix" {
  description = "Prefix for all resource names. Defaults to 'hailbytes-{product}-{environment}'."
  type        = string
  default     = null
}

variable "instance_type" {
  description = "EC2 instance type for the HailBytes application node(s). Constrained to the portable m6i ladder; see the validation message. Defaults to the 8-vCore training floor."
  type        = string
  default     = "m6i.2xlarge"

  validation {
    # The portable ladder. Every entry is a stock m6i general-purpose shape at
    # the same 4 GB-per-vCore ratio as the Azure Dsv5 equivalent, so a
    # deployment can move between clouds without changing tier.
    condition = contains([
      "m6i.large",    # 2 vCPU  - phishing simulation only
      "m6i.xlarge",   # 4 vCPU  - phishing simulation only
      "m6i.2xlarge",  # 8 vCPU  - training floor and purchasable entry rung
      "m6i.4xlarge",  # 16 vCPU
      "m6i.8xlarge",  # 32 vCPU
      "m6i.12xlarge", # 48 vCPU
      "m6i.16xlarge", # 64 vCPU
    ], var.instance_type)
    error_message = "instance_type must be a portable HailBytes rung: m6i.large (2 vCPU), m6i.xlarge (4), m6i.2xlarge (8), m6i.4xlarge (16), m6i.8xlarge (32), m6i.12xlarge (48), m6i.16xlarge (64). AWS m6i has NO general-purpose size between 16 and 32 vCPU, so a 24-vCore deployment cannot be delivered as one VM or as a symmetric pair (2 x 12 does not exist either) -- quote 16 or 32. The 2 and 4 vCPU rungs are for phishing-simulation-only instances: anything serving training content or running the recurring automations carries an 8-vCore floor."
  }
}

variable "key_name" {
  description = "EC2 key pair name. Optional; prefer SSM Session Manager for management access. Pass null to skip."
  type        = string
  default     = null
}

variable "root_volume_size_gb" {
  description = "Root volume size in GB."
  type        = number
  default     = 100
}

variable "data_volume_size_gb" {
  description = "Data volume size in GB. Attached as /dev/sdh; the marketplace image mounts and formats on first boot."
  type        = number
  default     = 200
}

variable "enable_customer_managed_key" {
  description = "Create and use a customer-managed KMS key for EBS encryption. If false, uses the AWS-managed default key."
  type        = bool
  default     = false
}

variable "enable_management_access" {
  description = "Attach the AmazonSSMManagedInstanceCore policy so the VM is reachable via SSM Session Manager. Strongly recommended."
  type        = bool
  default     = true
}

variable "associate_public_ip" {
  description = "Attach a public IP to the VM. Disabled by default; deploy into a private subnet behind a NAT or LB."
  type        = bool
  default     = false
}

variable "allow_internet_ingress" {
  description = "Permit 0.0.0.0/0 in allowed_cidrs. Emits no warning; you take responsibility."
  type        = bool
  default     = false
}

variable "enable_snapshots" {
  description = "Create a DLM lifecycle policy that snapshots the data volume daily and retains 7 snapshots."
  type        = bool
  default     = true
}

variable "marketplace_product_code" {
  description = "Optional AWS Marketplace product code. When set, the AMI lookup adds a product-code filter for stricter validation. Find it with: aws ec2 describe-images --owners aws-marketplace --filters 'Name=name,Values=hailbytes-*' --query 'Images[*].ProductCodes'"
  type        = string
  default     = null
}

# ----- Patching and migration safety -----

variable "create_backup_bucket" {
  description = "Provision an S3 bucket (versioning + object-lock governance + lifecycle to IA at 30d and Deep Archive at 90d) for pre-patch /api/instance/export bundles. The instance profile gets least-privilege PutObject on hailbytes-*.tar.gz."
  type        = bool
  default     = true
}

variable "backup_bucket_name" {
  description = "Name of an existing S3 bucket to use for pre-patch backups. If null and create_backup_bucket is true, the module names one '<name_prefix>-backups-<account_id>'."
  type        = string
  default     = null
}

variable "backup_object_lock_retention_days" {
  description = "Object Lock (governance mode) retention period for backup objects."
  type        = number
  default     = 30
}

variable "backup_noncurrent_version_expiration_days" {
  description = "Expire noncurrent versions of backup objects after this many days."
  type        = number
  default     = 365
}

variable "enable_flow_logs" {
  description = "Enable VPC Flow Logs for the provided VPC, sending ALL traffic to a CloudWatch log group named /aws/vpc-flow-logs/<name_prefix>. Matches the default stated in SECURITY-DEFAULTS.md."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "admin_port" {
  description = "Port the admin UI listens on inside the instance. Leave null to derive it from `product`: 3333 for SAT (the image's config.json `listen_url`), 443 for ASM (its proxy container publishes 443). Set it only if you have changed the port inside the image."
  type        = number
  default     = null
}

variable "phish_port" {
  description = "Port the phishing/tracking server listens on inside the instance. SAT only -- it is the landing-page and interaction-tracking surface, which is the product. Ignored when `product` is \"asm\", which has no phishing surface. Leave null for the image default of 80."
  type        = number
  default     = null
}
