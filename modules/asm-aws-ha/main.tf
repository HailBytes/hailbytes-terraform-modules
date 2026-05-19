module "this" {
  source                      = "../ha-hot-hot/aws"

  product                     = "asm"

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

  # Patching and migration safety
  db_mode                                   = var.db_mode
  db_ec2_instance_type                      = var.db_ec2_instance_type
  db_ec2_data_volume_size_gb                = var.db_ec2_data_volume_size_gb
  rds_backup_retention_period               = var.rds_backup_retention_period
  rds_copy_tags_to_snapshot                 = var.rds_copy_tags_to_snapshot
  create_backup_bucket                      = var.create_backup_bucket
  backup_bucket_name                        = var.backup_bucket_name
  backup_object_lock_retention_days         = var.backup_object_lock_retention_days
  backup_noncurrent_version_expiration_days = var.backup_noncurrent_version_expiration_days
  refresh_rollback_5xx_threshold_pct        = var.refresh_rollback_5xx_threshold_pct
  waf_web_acl_arn                           = var.waf_web_acl_arn
  alert_email                               = var.alert_email
  schema_version_endpoint_path              = var.schema_version_endpoint_path

  # Shared session store (ElastiCache for Redis)
  enable_managed_redis          = var.enable_managed_redis
  redis_node_type               = var.redis_node_type
  redis_engine_version          = var.redis_engine_version
  redis_snapshot_retention_days = var.redis_snapshot_retention_days
  redis_endpoint_override       = var.redis_endpoint_override
  redis_endpoint_override_port  = var.redis_endpoint_override_port
  redis_endpoint_override_tls   = var.redis_endpoint_override_tls

  tags = var.tags
}
