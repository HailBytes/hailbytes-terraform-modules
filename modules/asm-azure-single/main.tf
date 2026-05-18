module "this" {
  source                      = "../single-vm/azure"

  product                     = "asm"

  resource_group_name         = var.resource_group_name
  location                    = var.location
  subnet_id                   = var.subnet_id
  allowed_cidrs               = var.allowed_cidrs
  admin_username              = var.admin_username
  ssh_public_key              = var.ssh_public_key
  environment                 = var.environment
  name_prefix                 = var.name_prefix
  vm_size                     = var.vm_size
  os_disk_size_gb             = var.os_disk_size_gb
  data_disk_size_gb           = var.data_disk_size_gb
  enable_customer_managed_key = var.enable_customer_managed_key
  key_vault_id                = var.key_vault_id
  associate_public_ip         = var.associate_public_ip
  allow_internet_ingress      = var.allow_internet_ingress
  accept_marketplace_terms    = var.accept_marketplace_terms
  marketplace_sku_override    = var.marketplace_sku_override
  marketplace_image_version   = var.marketplace_image_version
  tags                        = var.tags
}
