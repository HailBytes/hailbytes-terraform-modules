# `sat-azure-ha`

HailBytes SAT (Security Awareness Training / phishing simulation) deployed on Azure — **HA hot-hot (2x active/active behind a load balancer with managed Postgres)** tier.

This module is a thin wrapper around [`modules/ha-hot-hot/azure`](../ha-hot-hot/azure) with `product = "sat"` hardcoded. All other variables, defaults, outputs, security posture, and marketplace lookup logic come from the inner tier module — see its README for the architecture diagram, cost estimate, prerequisites, and detailed inputs.

## Usage

> No `v1.0.0` tag exists yet ([#48](https://github.com/HailBytes/hailbytes-terraform-modules/issues/48)); pin to a commit SHA instead of `?ref=v1.0.0` until a tagged release ships.

```hcl
module "hailbytes_sat" {
  source = "github.com/hailbytes/hailbytes-terraform-modules//modules/sat-azure-ha?ref=v1.0.0"

  # ... see modules/ha-hot-hot/azure/README.md for required and optional variables
}
```

## Marketplace subscription

Before applying, subscribe to the **HailBytes SAT (Security Awareness Training / phishing simulation)** listing on Azure Marketplace. See the [top-level README](../../README.md#marketplace-subscriptions) for the subscription links.

## Inputs and outputs

See [`variables.tf`](variables.tf) and [`outputs.tf`](outputs.tf) in this directory. They mirror the inner module's surface, minus the hardcoded `product` variable.
