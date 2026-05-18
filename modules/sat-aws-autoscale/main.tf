module "this" {
  source                          = "../unlimited-scale/aws"

  product                         = "sat"

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
  tags                            = var.tags
}
