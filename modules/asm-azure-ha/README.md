# `asm-azure-ha`

HailBytes ASM (Attack Surface Management) deployed on Azure — **HA hot-hot (2x active/active behind a load balancer with managed Postgres)** tier.

This module is a thin wrapper around [`modules/ha-hot-hot/azure`](../ha-hot-hot/azure) with `product = "asm"` hardcoded. All other variables, defaults, outputs, security posture, and marketplace lookup logic come from the inner tier module — see its README for the architecture diagram, cost estimate, prerequisites, and detailed inputs.

## Usage

```hcl
module "hailbytes_asm" {
  source = "github.com/hailbytes/hailbytes-terraform-modules//modules/asm-azure-ha?ref=v1.0.0"

  # ... see modules/ha-hot-hot/azure/README.md for required and optional variables
}
```

## Marketplace subscription

Before applying, subscribe to the **HailBytes ASM (Attack Surface Management)** listing on Azure Marketplace. See the [top-level README](../../README.md#marketplace-subscriptions) for the subscription links.

## Inputs and outputs

See [`variables.tf`](variables.tf) and [`outputs.tf`](outputs.tf) in this directory. They mirror the inner module's surface, minus the hardcoded `product` variable.
