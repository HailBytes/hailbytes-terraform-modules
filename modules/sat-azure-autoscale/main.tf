module "this" {
  source                    = "../unlimited-scale/azure"

  product                   = "sat"

  resource_group_name       = var.resource_group_name
  location                  = var.location
  vm_subnet_id              = var.vm_subnet_id
  db_delegated_subnet_id    = var.db_delegated_subnet_id
  private_dns_zone_id       = var.private_dns_zone_id
  allowed_cidrs             = var.allowed_cidrs
  admin_username            = var.admin_username
  ssh_public_key            = var.ssh_public_key
  vmss_min_count            = var.vmss_min_count
  vmss_max_count            = var.vmss_max_count
  vmss_default_count        = var.vmss_default_count
  vm_size                   = var.vm_size
  target_cpu_percent        = var.target_cpu_percent
  db_sku_name               = var.db_sku_name
  db_storage_mb             = var.db_storage_mb
  db_version                = var.db_version
  db_backup_retention_days  = var.db_backup_retention_days
  db_replica_count          = var.db_replica_count
  environment               = var.environment
  name_prefix               = var.name_prefix
  alert_email               = var.alert_email
  accept_marketplace_terms  = var.accept_marketplace_terms
  marketplace_sku_override  = var.marketplace_sku_override
  marketplace_image_version = var.marketplace_image_version
  tags                      = var.tags
}
