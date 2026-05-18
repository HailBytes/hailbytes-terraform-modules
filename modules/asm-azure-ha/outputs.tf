# Outputs re-exported from modules/ha-hot-hot/azure.

output "load_balancer_public_ip" {
  value     = module.this.load_balancer_public_ip
  sensitive = false
}

output "load_balancer_id" {
  value     = module.this.load_balancer_id
  sensitive = false
}

output "vm_ids" {
  value     = module.this.vm_ids
  sensitive = false
}

output "vm_private_ips" {
  value     = module.this.vm_private_ips
  sensitive = false
}

output "postgres_fqdn" {
  value     = module.this.postgres_fqdn
  sensitive = false
}

output "key_vault_uri" {
  value     = module.this.key_vault_uri
  sensitive = false
}
