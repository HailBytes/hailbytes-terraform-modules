module "this" {
  source = "../unlimited-scale/aws"

  product = "asm"

  vpc_id                          = var.vpc_id
  public_subnet_ids               = var.public_subnet_ids
  private_subnet_ids              = var.private_subnet_ids
  allowed_cidrs                   = var.allowed_cidrs
  acm_certificate_arn             = var.acm_certificate_arn
  alert_email                     = var.alert_email
  asg_min_size                    = var.asg_min_size
  asg_max_size                    = var.asg_max_size
  asg_desired_capacity            = var.asg_desired_capacity
  instance_type                   = var.instance_type
  target_cpu_utilization          = var.target_cpu_utilization
  target_request_count_per_target = var.target_request_count_per_target
  db_instance_class               = var.db_instance_class
  db_allocated_storage_gb         = var.db_allocated_storage_gb
  db_max_allocated_storage_gb     = var.db_max_allocated_storage_gb
  db_engine_version               = var.db_engine_version
  db_backup_retention_days        = var.db_backup_retention_days
  db_read_replica_count           = var.db_read_replica_count
  db_deletion_protection          = var.db_deletion_protection
  environment                     = var.environment
  name_prefix                     = var.name_prefix
  enable_customer_managed_key     = var.enable_customer_managed_key
  alb_min_tls_version             = var.alb_min_tls_version
  enable_flow_logs                = var.enable_flow_logs
  access_log_retention_days       = var.access_log_retention_days
  marketplace_product_code        = var.marketplace_product_code
  enable_http_redirect            = var.enable_http_redirect

  # Patching and migration safety
  create_backup_bucket                      = var.create_backup_bucket
  backup_bucket_name                        = var.backup_bucket_name
  backup_object_lock_retention_days         = var.backup_object_lock_retention_days
  backup_noncurrent_version_expiration_days = var.backup_noncurrent_version_expiration_days
  instance_refresh_min_healthy_percentage   = var.instance_refresh_min_healthy_percentage
  instance_refresh_instance_warmup_seconds  = var.instance_refresh_instance_warmup_seconds
  refresh_rollback_5xx_threshold_pct        = var.refresh_rollback_5xx_threshold_pct
  waf_web_acl_arn                           = var.waf_web_acl_arn
  rds_copy_tags_to_snapshot                 = var.rds_copy_tags_to_snapshot
  schema_version_endpoint_path              = var.schema_version_endpoint_path

  # Shared session store (ElastiCache for Redis)
  enable_managed_redis          = var.enable_managed_redis
  redis_node_type               = var.redis_node_type
  redis_engine_version          = var.redis_engine_version
  redis_snapshot_retention_days = var.redis_snapshot_retention_days
  redis_endpoint_override       = var.redis_endpoint_override
  redis_endpoint_override_port  = var.redis_endpoint_override_port
  redis_endpoint_override_tls   = var.redis_endpoint_override_tls

  enable_alb_deletion_protection = var.enable_alb_deletion_protection

  # RDS production hardening (opt-in)
  rds_enhanced_monitoring_interval        = var.rds_enhanced_monitoring_interval
  rds_enabled_cloudwatch_log_types        = var.rds_enabled_cloudwatch_log_types
  rds_iam_authentication_enabled          = var.rds_iam_authentication_enabled
  rds_performance_insights_enabled        = var.rds_performance_insights_enabled
  rds_performance_insights_retention_days = var.rds_performance_insights_retention_days

  tags = var.tags
}
