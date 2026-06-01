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
  description = "EC2 instance type. t3.large is the default for ASM/SAT single-vm tier."
  type        = string
  default     = "t3.large"
}

variable "key_name" {
  description = "EC2 key pair name. Optional; prefer SSM Session Manager for management access. Pass null to skip."
  type        = string
  default     = null
}

variable "root_volume_size_gb" {
  description = "Root volume size in GB."
  type        = number
  default     = 50
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
  description = "Provision an S3 bucket (versioning + object-lock governance + lifecycle to IA at 30d and Deep Archive at 90d) for pre-patch /api/instance/export bundles. The instance profile gets least-privilege PutObject on hailbytes-asm-*.tar.gz."
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
  description = "Enable VPC Flow Logs for the provided VPC, sending ALL traffic to a CloudWatch log group. Matches the default stated in SECURITY-DEFAULTS.md."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags applied to every resource."
  type        = map(string)
  default     = {}
}
