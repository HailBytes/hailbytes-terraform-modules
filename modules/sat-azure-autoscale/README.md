# `sat-azure-autoscale`

HailBytes SAT (Security Awareness Training / phishing simulation) deployed on Azure — **Auto-scaling (ASG / VMSS with read replicas and full observability)** tier.

This module is a thin wrapper around [`modules/unlimited-scale/azure`](../unlimited-scale/azure) with `product = "sat"` hardcoded. All other variables, defaults, outputs, security posture, and marketplace lookup logic come from the inner tier module — see its README for the architecture diagram, cost estimate, prerequisites, and detailed inputs.

## Usage

```hcl
module "hailbytes_sat" {
  source = "github.com/hailbytes/hailbytes-terraform-modules//modules/sat-azure-autoscale?ref=v1.0.0"

  # ... see modules/unlimited-scale/azure/README.md for required and optional variables
}
```

## Marketplace subscription

Before applying, subscribe to the **HailBytes SAT (Security Awareness Training / phishing simulation)** listing on Azure Marketplace. See the [top-level README](../../README.md#marketplace-subscriptions) for the subscription links.

## Inputs and outputs

See [`variables.tf`](variables.tf) and [`outputs.tf`](outputs.tf) in this directory. They mirror the inner module's surface, minus the hardcoded `product` variable.
