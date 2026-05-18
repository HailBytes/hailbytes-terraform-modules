module "this" {
  source                      = "../ha-hot-hot/aws"

  product                     = "sat"

  vpc_id                      = var.vpc_id
  public_subnet_ids           = var.public_subnet_ids
  private_subnet_ids          = var.private_subnet_ids
  allowed_cidrs               = var.allowed_cidrs
  acm_certificate_arn         = var.acm_certificate_arn
  environment                 = var.environment
  name_prefix                 = var.name_prefix
  instance_type               = var.instance_type
  data_volume_size_gb         = var.data_volume_size_gb
  key_name                    = var.key_name
  db_instance_class           = var.db_instance_class
  db_allocated_storage_gb     = var.db_allocated_storage_gb
  db_max_allocated_storage_gb = var.db_max_allocated_storage_gb
  db_engine_version           = var.db_engine_version
  db_backup_retention_days    = var.db_backup_retention_days
  db_deletion_protection      = var.db_deletion_protection
  enable_customer_managed_key = var.enable_customer_managed_key
  alb_idle_timeout_seconds    = var.alb_idle_timeout_seconds
  alb_min_tls_version         = var.alb_min_tls_version
  enable_management_access    = var.enable_management_access
  marketplace_product_code    = var.marketplace_product_code
  enable_http_redirect        = var.enable_http_redirect
  tags                        = var.tags
}
