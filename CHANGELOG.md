# Changelog

All notable changes to this project are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [SemVer](https://semver.org/).

## [Unreleased]

### Added
- Initial repository scaffold
- `modules/single-vm/{aws,azure}` — single marketplace VM deployment
- `modules/ha-hot-hot/{aws,azure}` — active/active behind LB with managed Postgres
- `modules/unlimited-scale/{aws,azure}` — ASG/VMSS with read replicas and full observability
- `modules/network/{aws,azure}` — optional bundled landing zone (VPC/vnet + tiered subnets + NAT/private DNS); salvaged scaffolding from the deprecated byoc-security-architecture-templates repo
- Real marketplace identifiers wired as defaults:
  - AWS product codes: `1n57wg1f6735e30vj5fn420bp` (ASM) and `d19hjbz3gakqdlonlf8twdmll` (SAT); AMI lookup filters on product-code by default
  - Azure: publisher `lcmcon1687976613543`, offers `hardened_ubuntu_with_rengine` (ASM) and `gophish-phishing-simulator` (SAT), SKU `standard-v2`
- Optional `marketplace_product_code` variable on AWS modules for per-deploy overrides
- Optional `marketplace_sku_override` and `marketplace_image_version` variables on Azure modules
- HTTP→HTTPS 301 redirect listener on `ha-hot-hot/aws` and `unlimited-scale/aws` ALBs (default-on, `enable_http_redirect`)
- Postgres slow-query logging (`log_min_duration_statement=1000`) on RDS parameter groups
- Product-first wrapper modules (the public API): `asm-aws-{single,ha,autoscale}`, `asm-azure-{single,ha,autoscale}`, `sat-aws-{single,ha,autoscale}`, `sat-azure-{single,ha,autoscale}` — 12 thin wrappers around the 6 internal tier modules with `product` hardcoded
- SAT auto-scaling tiers (`sat-aws-autoscale`, `sat-azure-autoscale`) for large-population training campaigns and bursty report generation
- Azure auto-scaling for ASM (`asm-azure-autoscale`) — parity with the AWS side
- Top-level docs: README, ARCHITECTURE, BILLING, SECURITY (responsible disclosure), SECURITY-DEFAULTS (module-level posture)
- CI: `terraform validate`, `tflint`, `checkov`, `trivy` IaC scan — matrices expanded to cover all 20 modules
- MPL-2.0 license
