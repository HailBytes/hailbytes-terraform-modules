# `asm-azure-autoscale`

HailBytes ASM (Attack Surface Management) deployed on Azure — **Auto-scaling (ASG / VMSS with read replicas and full observability)** tier.

This module is a thin wrapper around [`modules/unlimited-scale/azure`](../unlimited-scale/azure) with `product = "asm"` hardcoded. All other variables, defaults, outputs, security posture, and marketplace lookup logic come from the inner tier module — see its README for the architecture diagram, cost estimate, prerequisites, and detailed inputs.

## Usage

> No `v1.0.0` tag exists yet ([#48](https://github.com/HailBytes/hailbytes-terraform-modules/issues/48)); pin to a commit SHA instead of `?ref=v1.0.0` until a tagged release ships.

```hcl
module "hailbytes_asm" {
  source = "github.com/hailbytes/hailbytes-terraform-modules//modules/asm-azure-autoscale?ref=v1.0.0"

  # ... see modules/unlimited-scale/azure/README.md for required and optional variables
}
```

## Marketplace subscription

Before applying, subscribe to the **HailBytes ASM (Attack Surface Management)** listing on Azure Marketplace. See the [top-level README](../../README.md#marketplace-subscriptions) for the subscription links.

## Inputs and outputs

See [`variables.tf`](variables.tf) and [`outputs.tf`](outputs.tf) in this directory. They mirror the inner module's surface, minus the hardcoded `product` variable.
