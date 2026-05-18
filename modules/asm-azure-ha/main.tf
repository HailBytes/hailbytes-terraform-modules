module "this" {
  source                    = "../ha-hot-hot/azure"

  product                   = "asm"

  resource_group_name       = var.resource_group_name
  location                  = var.location
  vm_subnet_id              = var.vm_subnet_id
  db_delegated_subnet_id    = var.db_delegated_subnet_id
  private_dns_zone_id       = var.private_dns_zone_id
  lb_subnet_id              = var.lb_subnet_id
  allowed_cidrs             = var.allowed_cidrs
  admin_username            = var.admin_username
  ssh_public_key            = var.ssh_public_key
  environment               = var.environment
  name_prefix               = var.name_prefix
  vm_size                   = var.vm_size
  data_disk_size_gb         = var.data_disk_size_gb
  db_sku_name               = var.db_sku_name
  db_storage_mb             = var.db_storage_mb
  db_version                = var.db_version
  db_backup_retention_days  = var.db_backup_retention_days
  db_high_availability_mode = var.db_high_availability_mode
  accept_marketplace_terms  = var.accept_marketplace_terms
  marketplace_sku_override  = var.marketplace_sku_override
  marketplace_image_version = var.marketplace_image_version
  tags                      = var.tags
}
