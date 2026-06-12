terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # Capped below 5.0: the modules still use enable_rbac_authorization and
      # storage_container resource_manager_id, whose 4.x replacements do not
      # exist in 3.x. Raise the floor to >= 4.0 and rename before allowing 5.x.
      version = ">= 3.0, < 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }
}
