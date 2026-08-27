module "this" {
  source = "../ha-hot-hot/azure"

  product = "asm"

  resource_group_name    = var.resource_group_name
  location               = var.location
  vm_subnet_id           = var.vm_subnet_id
  db_delegated_subnet_id = var.db_delegated_subnet_id
  private_dns_zone_id    = var.private_dns_zone_id
  lb_subnet_id           = var.lb_subnet_id
  allowed_cidrs          = var.allowed_cidrs
  phish_allowed_cidrs    = var.phish_allowed_cidrs
  health_check_path      = var.health_check_path
  admin_username         = var.admin_username
  ssh_public_key         = var.ssh_public_key

  # Key Vault network ACL
  db_log_min_duration_ms           = var.db_log_min_duration_ms
  enable_db_delete_lock            = var.enable_db_delete_lock
  key_vault_name                   = var.key_vault_name
  key_vault_network_default_action = var.key_vault_network_default_action
  key_vault_ip_rules               = var.key_vault_ip_rules
  associate_vm_subnet_nsg          = var.associate_vm_subnet_nsg
  vm_subnet_is_lb_subnet           = var.vm_subnet_is_lb_subnet
  environment                      = var.environment
  name_prefix                      = var.name_prefix
  vm_size                          = var.vm_size
  vm_names                         = var.vm_names
  db_vm_name                       = var.db_vm_name
  data_disk_size_gb                = var.data_disk_size_gb
  enable_customer_managed_key      = var.enable_customer_managed_key
  db_sku_name                      = var.db_sku_name
  db_storage_mb                    = var.db_storage_mb
  db_version                       = var.db_version
  db_backup_retention_days         = var.db_backup_retention_days
  db_high_availability_mode        = var.db_high_availability_mode
  accept_marketplace_terms         = var.accept_marketplace_terms
  marketplace_sku_override         = var.marketplace_sku_override
  marketplace_image_version        = var.marketplace_image_version

  # Patching and migration safety
  db_mode                                = var.db_mode
  db_vm_size                             = var.db_vm_size
  db_vm_data_disk_size_gb                = var.db_vm_data_disk_size_gb
  create_backup_storage_account          = var.create_backup_storage_account
  backup_storage_account_name            = var.backup_storage_account_name
  backup_storage_replication             = var.backup_storage_replication
  backup_immutability_days               = var.backup_immutability_days
  backup_blob_soft_delete_days           = var.backup_blob_soft_delete_days
  backup_blob_noncurrent_expiration_days = var.backup_blob_noncurrent_expiration_days
  enable_pre_patch_run_command           = var.enable_pre_patch_run_command
  enable_application_gateway             = var.enable_application_gateway
  public_ip_id                           = var.public_ip_id
  key_vault_reader_principal_ids         = var.key_vault_reader_principal_ids
  appgw_subnet_id                        = var.appgw_subnet_id
  appgw_tls_pfx_base64                   = var.appgw_tls_pfx_base64
  appgw_tls_pfx_password                 = var.appgw_tls_pfx_password
  appgw_backend_host_header              = var.appgw_backend_host_header
  waf_policy_id                          = var.waf_policy_id
  alert_email                            = var.alert_email
  refresh_rollback_5xx_count_threshold   = var.refresh_rollback_5xx_count_threshold
  schema_version_endpoint_path           = var.schema_version_endpoint_path
  enable_post_patch_run_command          = var.enable_post_patch_run_command

  # Shared session store (Azure Cache for Redis)
  enable_managed_redis         = var.enable_managed_redis
  redis_sku_name               = var.redis_sku_name
  redis_family                 = var.redis_family
  redis_capacity               = var.redis_capacity
  redis_endpoint_override      = var.redis_endpoint_override
  redis_endpoint_override_port = var.redis_endpoint_override_port
  redis_endpoint_override_tls  = var.redis_endpoint_override_tls

  db_secret_expiration_hours = var.db_secret_expiration_hours

  postgres_geo_redundant_backup_enabled = var.postgres_geo_redundant_backup_enabled

  tags                             = var.tags
  redis_private_dns_zone_id        = var.redis_private_dns_zone_id
  redis_private_endpoint_subnet_id = var.redis_private_endpoint_subnet_id
  admin_port                       = var.admin_port
  phish_port                       = var.phish_port

  external_db_host     = var.external_db_host
  external_db_port     = var.external_db_port
  external_db_name     = var.external_db_name
  external_db_username = var.external_db_username
  external_db_password = var.external_db_password
  external_db_sslmode  = var.external_db_sslmode

  appgw_backend_protocol      = var.appgw_backend_protocol
  appgw_backend_port          = var.appgw_backend_port
  appgw_backend_root_cert_pem = var.appgw_backend_root_cert_pem

  enable_diagnostics         = var.enable_diagnostics
  log_analytics_workspace_id = var.log_analytics_workspace_id
  diagnostics_retention_days = var.diagnostics_retention_days
  enable_management_access   = var.enable_management_access

}
