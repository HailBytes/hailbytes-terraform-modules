module "this" {
  source = "../single-vm/aws"

  product = "asm"

  vpc_id                      = var.vpc_id
  subnet_id                   = var.subnet_id
  allowed_cidrs               = var.allowed_cidrs
  environment                 = var.environment
  name_prefix                 = var.name_prefix
  instance_type               = var.instance_type
  key_name                    = var.key_name
  root_volume_size_gb         = var.root_volume_size_gb
  data_volume_size_gb         = var.data_volume_size_gb
  enable_customer_managed_key = var.enable_customer_managed_key
  enable_management_access    = var.enable_management_access
  associate_public_ip         = var.associate_public_ip
  allow_internet_ingress      = var.allow_internet_ingress
  enable_snapshots            = var.enable_snapshots
  marketplace_product_code    = var.marketplace_product_code

  # Patching and migration safety
  create_backup_bucket                      = var.create_backup_bucket
  backup_bucket_name                        = var.backup_bucket_name
  backup_object_lock_retention_days         = var.backup_object_lock_retention_days
  backup_noncurrent_version_expiration_days = var.backup_noncurrent_version_expiration_days

  tags = var.tags
}
