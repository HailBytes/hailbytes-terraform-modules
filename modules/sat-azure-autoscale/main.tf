module "this" {
  source = "../unlimited-scale/azure"

  product = "sat"

  resource_group_name    = var.resource_group_name
  location               = var.location
  vm_subnet_id           = var.vm_subnet_id
  db_delegated_subnet_id = var.db_delegated_subnet_id
  private_dns_zone_id    = var.private_dns_zone_id
  allowed_cidrs          = var.allowed_cidrs
  admin_username         = var.admin_username
  ssh_public_key         = var.ssh_public_key

  # Key Vault network ACL + VMSS subnet NSG association
  key_vault_network_default_action = var.key_vault_network_default_action
  key_vault_ip_rules               = var.key_vault_ip_rules
  associate_vm_subnet_nsg          = var.associate_vm_subnet_nsg
  vmss_min_count                   = var.vmss_min_count
  vmss_max_count                   = var.vmss_max_count
  vmss_default_count               = var.vmss_default_count
  vm_size                          = var.vm_size
  target_cpu_percent               = var.target_cpu_percent
  db_sku_name                      = var.db_sku_name
  db_storage_mb                    = var.db_storage_mb
  db_version                       = var.db_version
  db_backup_retention_days         = var.db_backup_retention_days
  db_replica_count                 = var.db_replica_count
  environment                      = var.environment
  name_prefix                      = var.name_prefix
  alert_email                      = var.alert_email
  accept_marketplace_terms         = var.accept_marketplace_terms
  marketplace_sku_override         = var.marketplace_sku_override
  marketplace_image_version        = var.marketplace_image_version

  # Patching and migration safety
  create_backup_storage_account          = var.create_backup_storage_account
  backup_storage_account_name            = var.backup_storage_account_name
  backup_storage_replication             = var.backup_storage_replication
  backup_immutability_days               = var.backup_immutability_days
  backup_blob_soft_delete_days           = var.backup_blob_soft_delete_days
  backup_blob_noncurrent_expiration_days = var.backup_blob_noncurrent_expiration_days
  enable_pre_patch_run_command           = var.enable_pre_patch_run_command
  rolling_upgrade_max_batch_percent      = var.rolling_upgrade_max_batch_percent
  rolling_upgrade_max_unhealthy_percent  = var.rolling_upgrade_max_unhealthy_percent
  enable_application_gateway             = var.enable_application_gateway
  appgw_subnet_id                        = var.appgw_subnet_id
  appgw_tls_pfx_base64                   = var.appgw_tls_pfx_base64
  appgw_tls_pfx_password                 = var.appgw_tls_pfx_password
  appgw_backend_host_header              = var.appgw_backend_host_header
  waf_policy_id                          = var.waf_policy_id
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

  tags = var.tags
}
