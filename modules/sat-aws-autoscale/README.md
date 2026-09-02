# `sat-aws-autoscale`

HailBytes SAT (Security Awareness Training / phishing simulation) deployed on AWS — **Auto-scaling (ASG / VMSS with read replicas and full observability)** tier.

This module is a thin wrapper around [`modules/unlimited-scale/aws`](../unlimited-scale/aws) with `product = "sat"` hardcoded. All other variables, defaults, outputs, security posture, and marketplace lookup logic come from the inner tier module — see its README for the architecture diagram, cost estimate, prerequisites, and detailed inputs.

## Usage

> No `v1.0.0` tag exists yet ([#48](https://github.com/HailBytes/hailbytes-terraform-modules/issues/48)); pin to a commit SHA instead of `?ref=v1.0.0` until a tagged release ships.

```hcl
module "hailbytes_sat" {
  source = "github.com/hailbytes/hailbytes-terraform-modules//modules/sat-aws-autoscale?ref=v1.0.0"

  # ... see modules/unlimited-scale/aws/README.md for required and optional variables
}
```

## Phishing frontend and the two allow-lists

SAT fronts two surfaces with opposite audiences: the admin console on **443**
(governed by `allowed_cidrs`, for your operators) and the phishing landing pages
plus their click/open tracking on **80** (governed by `phish_allowed_cidrs`, for
your simulation targets). `phish_allowed_cidrs` defaults to `null`, which
inherits `allowed_cidrs` — and for a real simulation that is almost always
wrong, because a console locked to an office range locks every target out of the
landing pages while the campaign still sends:

```hcl
allowed_cidrs       = ["203.0.113.0/24"]  # operators only
phish_allowed_cidrs = ["0.0.0.0/0"]       # targets, i.e. the internet
```

`enable_http_redirect` is inert here: on SAT `:80` carries the landing pages,
so reach the console on 443 directly.

See [`modules/unlimited-scale/aws/README.md`](../unlimited-scale/aws/README.md#network-exposure-two-surfaces-two-allow-lists) for the health-check
reasoning and the full ports table.

## Marketplace subscription

Before applying, subscribe to the **HailBytes SAT (Security Awareness Training / phishing simulation)** listing on AWS Marketplace. See the [top-level README](../../README.md#marketplace-subscriptions) for the subscription links.

## Inputs and outputs

See [`variables.tf`](variables.tf) and [`outputs.tf`](outputs.tf) in this directory. They mirror the inner module's surface, minus the hardcoded `product` variable.
