# `network/azure`

Opinionated virtual network scaffolding for HailBytes workload modules. Vnet + workload subnet + LB subnet + delegated Postgres subnet + private DNS zone for vnet-integrated Flexible Server.

**You do not need this module if you already have a vnet.** The workload modules accept subnet IDs and DNS zone IDs directly.

## Usage

> No `v1.0.0` tag exists yet ([#48](https://github.com/HailBytes/hailbytes-terraform-modules/issues/48)); pin to a commit SHA instead of `?ref=v1.0.0` until a tagged release ships.

```hcl
resource "azurerm_resource_group" "main" {
  name     = "rg-hailbytes-prod"
  location = "eastus"
}

module "network" {
  source = "github.com/hailbytes/hailbytes-terraform-modules//modules/network/azure?ref=v1.0.0"

  name_prefix         = "hailbytes-asm-prod"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

module "hailbytes_asm_ha" {
  source = "github.com/hailbytes/hailbytes-terraform-modules//modules/ha-hot-hot/azure?ref=v1.0.0"

  product                = "asm"
  resource_group_name    = azurerm_resource_group.main.name
  location               = azurerm_resource_group.main.location
  vm_subnet_id           = module.network.workload_subnet_id
  lb_subnet_id           = module.network.lb_subnet_id
  db_delegated_subnet_id = module.network.db_delegated_subnet_id
  private_dns_zone_id    = module.network.private_dns_zone_id
  allowed_cidrs          = ["10.0.0.0/8"]
  admin_username         = "hbadmin"
  ssh_public_key         = file("~/.ssh/id_ed25519.pub")
}
```

## What it creates

- `azurerm_virtual_network` (/16 by default)
- Workload subnet (/24, for VMs / VMSS)
- LB subnet (/24, for internal LBs if used)
- DB subnet (/24, delegated to `Microsoft.DBforPostgreSQL/flexibleServers`)
- Private DNS zone `privatelink.postgres.database.azure.com` linked to the vnet

## Inputs / Outputs

See [`variables.tf`](variables.tf) and [`outputs.tf`](outputs.tf).
