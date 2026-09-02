# Changelog

All notable changes to this project are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [SemVer](https://semver.org/).

## [Unreleased]

### Added

- **`ha-hot-hot/azure` (and `asm-azure-ha` / `sat-azure-ha`): `lb_frontend_public`, to stop traffic bypassing the App Gateway.** The gateway does not sit *in front of* the load balancer — its backend pool points at `azurerm_network_interface.vm[*].private_ip_address`, so the two are **parallel** public entry points to the same `admin_port`. An operator who enabled the gateway specifically to attach a `waf_policy_id` therefore still had a second, un-WAF-ed public route to that port, and no way to close it short of giving up the gateway.

  `lb_frontend_public = false` (valid only with `enable_application_gateway = true`) gives the load-balancer frontend a private address in `lb_subnet_id`, leaving the gateway as the single public route. Two contradictions are refused at plan time rather than silently resolved: without the gateway, an internal frontend would leave nothing publicly reachable at all; and with `public_ip_id`, one of the two inputs would have to be ignored (the gateway's address is `appgw_public_ip_id`).

  **What this does not close.** `var.allowed_cidrs` already bounded both paths, so this was never an open internet surface — it is defence in depth, and it matters most where a WAF policy is attached. It also does not change the *default*: `true` preserves today's behaviour exactly, so no existing deployment moves.

  **Check your egress before setting it.** This module defines no outbound rule, so backend VMs take implicit outbound SNAT from the load balancer's public frontend. Making it internal removes that path. `network/azure` attaches a NAT Gateway to the workload subnet by default and a NAT Gateway takes precedence over LB SNAT regardless, so the documented composition is unaffected — but a hand-built network with no NAT Gateway and no other egress would lose outbound internet, which for SAT means campaign email stops leaving.

  The same gap exists in `unlimited-scale/azure`, where the scale set is a member of both backend pools. It is **not** closed there yet — that public IP has no `count` to branch and the pool membership needs the same treatment — so it is recorded in a comment above the resource instead of half-fixed.

- **`quickstart/azure-ha-byoip`: a first-class path for bring-your-own IP and TLS on your own domain.** [`quickstart/azure-ha`](quickstart/azure-ha) passes neither `public_ip_id` nor any `appgw_*` input, and the `network/azure` module it composes with creates no Application Gateway subnet — so the three things customers running their own authoritative DNS actually ask for (register the A record *before* the first apply, terminate TLS with their own certificate on their own hostname, and name the VMs to a host-naming standard) were reachable only by hand-writing a root module. This quickstart does all three, and documents the two-phase apply that TLS forces.

- **`ha-hot-hot/azure` (and `asm-azure-ha` / `sat-azure-ha`): `appgw_public_ip_id`, to bring your own Application Gateway frontend address.** `public_ip_id` fronts the **load balancer**. When `enable_application_gateway = true` the gateway becomes the front door and the load balancer becomes an internal hop, so a customer who had reserved an address and pre-registered DNS against it found the console answering on a module-created address instead — with no input available to change that. Same contract as `public_ip_id`: Static, Standard SKU, lifecycle stays the caller's, so the address survives a `terraform destroy` and the DNS record stays valid across a rebuild.

- **`ha-hot-hot/azure` (and both HA wrappers): a `key_vault_id` output.** The apply identity receives *Key Vault Secrets Officer*, so when the apply runs as a service principal no human can read or rotate the database password or the shared session keys. Granting an operator afterwards needs the vault's **resource ID** as the role-assignment scope, and the existing `key_vault_uri` output cannot be used for that — callers were left reconstructing the ID by hand. With this, break-glass access is a one-liner against `terraform output` and needs no re-apply:

  ```
  az role assignment create --role "Key Vault Secrets User" \
    --assignee <upn-or-object-id> --scope "$(terraform output -raw key_vault_id)"
  ```

### Fixed

- **`unlimited-scale` served no phishing landing pages on either cloud, so SAT's product surface was missing from the tier sold to MSSPs and large enterprises.** SAT *is* phishing simulation: the landing pages and the click/open tracking behind them are the deliverable. `modules/ha-hot-hot/azure/main.tf` already states the principle — an HA pair that only fronts the admin port is not serving the product — and the autoscale tier had exactly that shape. `local.phish_port` was computed in both `unlimited-scale/aws` and `unlimited-scale/azure` and **never referenced**: no target group, no port-80 forwarding rule, no security-group or NSG rule. A SAT autoscale deployment sent its campaign, and every target that clicked reached nothing. No open and no click was recorded, so the failure was silent on the operator's side.

  This was a deliberate deferral, not an oversight — the previous release wired `admin_port` and left the phishing frontend for a follow-up, on the grounds that adding one is a feature rather than a port correction. This is that follow-up.

  **AWS.** For `product = "sat"` the ALB's `:80` listener now forwards to a new phishing target group on `phish_port` instead of 301-redirecting to HTTPS, the ALB's egress and the instances' ingress both open `phish_port`, and the ASG registers instances in both target groups. `enable_http_redirect` (default `true`) becomes **ASM-only and inert on SAT**: `:80` cannot both redirect and serve landing pages, and a 301 sent to a target who clicked a phishing link breaks the simulation. It is gated rather than rejected so the default stays valid for both products — a validation error would have failed `plan` for every SAT caller until they edited their tfvars.

  The target group's health check is the load-bearing part. `ha-hot-hot/azure` probes over `Tcp` deliberately, because landing pages are campaign-specific and no path on the phish server is guaranteed to answer 200 on a fresh deployment. An ALB is `load_balancer_type = "application"` and cannot do TCP checks, so the equivalent is a permissive matcher on `/` rather than a guessed path: `/` falls through the phish server's catch-all route to `PhishHandler`, which answers **404** when the request carries no campaign RID; a landing page with a configured redirect answers **302**; a live campaign URL answers **200**. All three mean the server is up and routing, so the matcher is `200-499` and only 5xx drains a target. Narrowing it would reproduce the empty-pool / permanent-503 failure the `admin_port` fix cured, and would bite harder here — the ASG runs `health_check_type = "ELB"`, so an unhealthy phishing target gets the whole instance terminated and replaced.

  **Azure.** For `product = "sat"` the Standard Load Balancer gains a `Tcp` probe on `phish_port` and a rule fronting `:80`, plus a VMSS NSG rule in its own 1000+ priority band — the same four resources `ha-hot-hot/azure` uses, with the same reasoning. The **Application Gateway deliberately does not carry the phishing surface**: it exists in this module for the WAF story, and an OWASP-style ruleset in front of a simulated credential-harvest page blocks the very interactions the product exists to record. It is also opt-in and off by default, so routing the product's primary surface through it would have shipped the fix to almost nobody. The gateway fronts the admin console; the load balancer fronts the landing pages. The VMSS keeps `health_probe_id` on the admin probe, so a phishing-surface blip drops an instance out of the `:80` rotation without reimaging it.

  **A separate phishing allow-list, on both clouds.** New `phish_allowed_cidrs` on both tier modules and all four autoscale wrappers, which neither tier had. It matters for the same reason it did on the other tiers: the console is for operators on an office or VPN range, and the landing pages are for simulation targets, who are by definition somewhere else. With one shared list, an operator who locks the console down also locks every target out of the landing pages. It defaults to `null`, inheriting `allowed_cidrs`, and is inert on ASM. `unlimited-scale` has no `allow_internet_ingress` flag, so nothing here introduces a `0.0.0.0/0` default — a live simulation sets the list explicitly.

  Two `tflint` `terraform_unused_declarations` warnings on `local.phish_port` are resolved as a side effect. Deleting the local would only have relocated the warning to `variable "phish_port"`, and removing the variable would have broken all four wrappers with `Unsupported argument` — a breaking change to the public API for a lint fix.

  **Upgrade impact.**

  | Cloud | Product | What changes |
  |---|---|---|
  | AWS | SAT | **Creates** a phishing target group and a `:80` forward listener; **destroys** the `:80` redirect listener and its `alb_http_redirect` ingress rules, **replacing** them with `alb_phish` rules on the same port. **Creates** one ALB egress and one instance ingress rule on `phish_port`. The ASG's `target_group_arns` **updates in place** to register both groups; instances are not replaced. |
  | AWS | ASM | **No-op.** The `:80` redirect, its ingress rules and the admin target group are untouched. |
  | Azure | SAT | **Creates** an LB probe, an LB rule and one NSG rule per phishing CIDR. Nothing is replaced; the VMSS is not reimaged. |
  | Azure | ASM | **No-op.** |

  **The public frontend ports do not change on any tier.** 443 stays the admin console and 80 stays the port `:80` was already bound to — on SAT it now answers with landing pages instead of a redirect, which is the fix. With `phish_allowed_cidrs` left `null` the phishing surface inherits `allowed_cidrs`, so the set of CIDRs permitted on `:80` is unchanged by the upgrade; only the resource addresses carrying them move. Existing SAT deployments that relied on the `:80` redirect for operator convenience should reach the console on 443 directly.

  Regression coverage in `modules/unlimited-scale/aws/tests/feature_flags.tftest.hcl` and `modules/unlimited-scale/azure/tests/feature_flags.tftest.hcl` asserts the SAT wiring, the health-check matcher and probe protocol, the allow-list inheritance default, that opening the phishing surface does not widen the admin one, and that an ASM plan creates none of it even when `phish_allowed_cidrs` is set.

  `ha-hot-hot/aws` had the identical gap and is fixed alongside it — see the next entry.

- **`ha-hot-hot/aws` sent real admin traffic to port 443 on instances that do not bind it, while the health check probed the right port and reported green.** `aws_lb_target_group.main` and its health check were corrected to `admin_port` in an earlier release, and the inline comment claimed "only the ALB-to-instance hop moves". The hop did not move for real traffic: `aws_lb_target_group_attachment.vm` carried a literal `port = 443`, and an attachment's `port` **overrides the target group's own** — it is the port on which targets actually receive traffic.

  So on SAT the ALB probed 3333 (`config.json` `admin_server.listen_url = 0.0.0.0:3333`), the probe succeeded, the target reported healthy and the pool looked green, while every request arriving on the 443 listener was forwarded to instance port 443, which nothing binds. **That is worse than the empty pool the `admin_port` fix cured**, because a healthy-looking target group presents as an application fault rather than a network one — there is nothing in the load-balancer console to suggest a misconfiguration.

  ASM was unaffected, but only by coincidence: its `admin_port` derives to 443, so the literal happened to agree. This tier was also the only one carrying the literal — `unlimited-scale/aws` registers instances through the ASG's `target_group_arns`, which inherits the target group's port, and `single-vm/aws` has no load balancer at all.

  The attachment now uses `local.admin_port`, and the target group's comment no longer claims a correction it did not deliver. Three regression runs in `modules/ha-hot-hot/aws/tests/feature_flags.tftest.hcl` assert the attachment port for SAT and for ASM, that an explicit `admin_port` override reaches the attachments too, and — the assertion that would have caught this — that the attachment port and the health-check port are **the same port**, since their disagreement was the entire bug.

  **Upgrade impact:** `port` is part of an attachment's identity, so changing it **replaces both attachments** on SAT — each instance is deregistered from the admin target group and re-registered on 3333. Terraform does not order the two replacements, so plan for both nodes to be briefly out of the admin rotation at once and apply during a window, or apply with `-target` per instance to keep one node serving. Nothing else is replaced: no instance, no database, no listener, and the public 443/80 frontend is untouched. **For ASM the derived value is already 443 and the plan is a no-op.** The phishing attachments added above are unaffected — they were written against `local.phish_port` from the start.

- **`ha-hot-hot/aws` served no phishing landing pages either, and did not even declare `phish_port`.** The same defect as the autoscale tier above, one step worse: on `unlimited-scale` the variable existed and was merely unwired, so an operator could at least see the intent. Here there was no `phish_port` at all — no target group, no port-80 forwarding rule, no security-group rule, and no input to set. SAT on the AWS HA tier sent its campaign and every target that clicked reached nothing. This is the tier most production SAT customers are running today, which is why it is fixed in the same release rather than deferred again.

  The wiring mirrors the autoscale fix exactly, and the reasoning behind each choice is identical, so it is not restated here: for `product = "sat"` the ALB's `:80` listener forwards to a phishing target group on `phish_port` with a `200-499` health-check matcher on `/`, both VMs are attached to it on `phish_port`, the ALB's egress and the VMs' ingress open `phish_port`, and `enable_http_redirect` (default `true`) becomes ASM-only and inert on SAT. New `phish_port` and `phish_allowed_cidrs` on the tier module and on both `sat-aws-ha` / `asm-aws-ha` wrappers, the latter defaulting to `null` so it inherits `allowed_cidrs`.

  One deliberate difference from the admin target group: the phishing group carries **no `stickiness` block**. A landing-page request carries its own recipient ID and is stateless, so pinning a target buys nothing and skews load across a two-node pair.

  **Upgrade impact.**

  | Product | What changes |
  |---|---|
  | SAT | **Creates** a phishing target group, a `:80` forward listener, and one target-group attachment per VM; **destroys** the `:80` redirect listener and its `alb_http_redirect` ingress rules, **replacing** them with `alb_phish` rules on the same port. **Creates** one ALB egress and one VM ingress rule on `phish_port`. **No instance is replaced or restarted.** |
  | ASM | **No-op.** |

  Public frontend ports are unchanged: 443 stays the admin console, and `:80` was already bound — on SAT it now answers with landing pages instead of a redirect. With `phish_allowed_cidrs` left `null`, the set of CIDRs permitted on `:80` is identical after the upgrade; only the resource addresses carrying them move. Existing SAT deployments that relied on the `:80` redirect should reach the console on 443 directly.

  Regression coverage in `modules/ha-hot-hot/aws/tests/feature_flags.tftest.hcl` asserts the SAT wiring, the health-check matcher and protocol, that every VM is attached to the phishing group on `phish_port`, the allow-list inheritance default, that opening the phishing surface does not widen the admin one, and that an ASM plan creates none of it even when `phish_allowed_cidrs` is set.

  With this and the entry above, **every tier now serves SAT's phishing surface on both clouds.**

- **`network/azure`: the workload subnet now carries the `Microsoft.KeyVault` service endpoint, without which the Key Vault cannot be created at all.** The workload tier modules put `vm_subnet_id` in their Key Vault's `network_acls.virtual_network_subnet_ids`, and Azure validates that **every** subnet named in a Key Vault ACL has that service endpoint — regardless of `key_vault_network_default_action`, so the default `"Allow"` did not avoid it. `azurerm_subnet.workload` declared no `service_endpoints`, so the composition this repo documents (`network/azure` feeding `ha-hot-hot/azure`, which is what both Azure HA quickstarts do) failed with `400 VirtualNetworkNotValid / SubnetsHaveNoServiceEndpointsConfigured`.

  **`terraform plan` could not catch this.** The check is server-side, so the plan succeeds and the apply fails partway through — with the resource group, VNet, Postgres server and Redis cache already created, which then have to be imported or deleted before a retry because they exist in Azure and not in state.

  Found on a customer's first real apply, not in CI. A caller bringing its own network still has to add the endpoint itself; that is now documented on `vm_subnet_id` in the tier module, where someone wiring a hand-built subnet would look. A `terraform test` run pins it — asserting the declared attribute, which is checkable under `mock_provider`, unlike Azure's response.

- **`ha-hot-hot/azure`: composing this module with `network/azure` in one apply no longer fails the plan.** Since [#51](https://github.com/HailBytes/hailbytes-terraform-modules/issues/51), five resources guarding the VM-subnet NSG branched on `var.vm_subnet_id != var.lb_subnet_id` through `count`/`for_each`. Terraform resolves those during **plan**, so any caller that creates its subnets in the same `terraform apply` — passing two IDs that are still *"known after apply"* — got `Error: Invalid count argument` and no plan at all. That is the composition this repo documents: `network/azure` outputs feeding the HA module, as in [`docs/AZURE_PATCHING_AND_MIGRATION.md`](docs/AZURE_PATCHING_AND_MIGRATION.md), [`docs/DEPLOY_FROM_GALLERY.md`](docs/DEPLOY_FROM_GALLERY.md), and the `network/azure` output descriptions. The `ha-hot-hot/azure` README's own example hit it too. It reproduced only against real subnet-creating callers, never in `terraform test`, because every fixture in the suite passes literal subnet ID strings.

  The branch is now the new `vm_subnet_is_lb_subnet` input (default `false`), which is known at plan time — matching how the sibling `unlimited-scale/azure` has always gated the same NSG. A `check` block reports a flag that disagrees with the actual IDs, on the first apply where both are known.

### Changed — BREAKING

- **Azure Storage-backed features now default OFF, because on their previous defaults the apply could not succeed.** `enable_flow_logs` on `network/azure` and `create_backup_storage_account` on all three Azure tier modules defaulted to `true`. Both create a Storage Account with `shared_access_key_enabled = false` **and** `public_network_access_enabled = false`, and this repo provisions no storage private endpoint and no `Microsoft.Storage` service endpoint. The `azurerm` provider nevertheless reads those accounts' **queue service properties over the storage data plane**, so an apply run from outside the VNet — Cloud Shell, a laptop, CI — failed with:

  ```
  403 KeyBasedAuthenticationNotPermitted
  "Key based authentication is not permitted on this storage account."
  ```

  Fixing the authentication does not help: `storage_use_azuread = true` moves the call to Entra, which the closed network then refuses instead. So these were not features with a caveat — with `enable_flow_logs` defaulting on, *every* caller composing `network/azure` hit an apply that could not complete. It fails on refresh as well as create, so once such an account exists a plain `terraform plan` cannot complete either.

  **Upgrade impact.** If you relied on either default and somehow have these accounts — an older provider version, or shared keys enabled out of band — the next `apply` will **destroy them**, including any backup bundles. Set the variable explicitly to `true` before upgrading to keep them. In practice a default-`true` apply could not succeed on a current provider, so most callers have nothing to lose here; check rather than assume.

- **The Azure backup Storage Account is now `account_kind = "BlobStorage"`, which REPLACES an existing account.** The provider only manages queue service properties for account kinds that support queues, so a blob-only kind removes the data-plane call that 403s. These bundles are blobs; nothing uses queues, files or tables. Applies to `ha-hot-hot/azure`, `single-vm/azure` and `unlimited-scale/azure`.

  **Upgrade impact.** `account_kind` is replacement-forcing: upgrading with `create_backup_storage_account = true` destroys and recreates the account and **loses any bundles in it**. Copy anything you need out first. Note also that this fix is **reasoned, not yet confirmed against a real apply** — which is why the default stays `false` rather than being turned back on alongside it.

  The flow-log account is deliberately **not** changed the same way: it is written by Azure Network Watcher rather than by us, and Network Watcher has its own requirements on the account type that need verifying before the kind is touched. With the default off, nobody is exposed to it meanwhile.

- **`ha-hot-hot/azure` (and `asm-azure-ha` / `sat-azure-ha`): a shared VM/LB subnet must now be declared, not inferred.** If you pass the *same* subnet ID to both `vm_subnet_id` and `lb_subnet_id`, set `vm_subnet_is_lb_subnet = true`. The module previously detected this by comparing the two IDs; that comparison is what broke every same-apply plan (see *Fixed* above), so it could not be kept.

  **Upgrade impact:** callers with two *distinct* subnets — the default, and everything `network/azure` produces — need no change. Callers sharing one subnet who do not set the flag will have Terraform plan a second NSG association on that subnet, which Azure rejects at apply, and the module's `check` block flags first. Nothing is silently unfiltered.

- **Application-node sizing defaults raised to the 8-vCore training floor, and constrained to a portable ladder.** All six tier modules and all twelve product wrappers previously defaulted to 2 vCPU (`t3.large` on AWS, `Standard_D2s_v5` on Azure) as a deliberately-cheap PoC "starter" shape. They now default to `m6i.2xlarge` / `Standard_D8s_v5` (8 vCore, 32 GB).

  *Why:* the old defaults shipped **below a hard engineering floor**. Per `hailbytes-sat/docs/VM_SCALING.md`, any instance serving training content or running the recurring automations needs 8 vCores — learner video/SCORM streams off local disk through the phish server, certificate PDFs render on the same box, and a one-minute worker tick sweeps recurring campaigns, certificate expiry, risk recomputation and remedial assignment, all contending with the co-located Postgres. Below 8 those workloads starve each other and the automation sweep slips its tick, which the customer sees as reminders arriving late. The floor is enforced per-instance in product code (`controllers/api/sizing.go`, `trainingVCoreFloor = 8`), and training ships with the phish server, so it is the default workload rather than an add-on. The old defaults also matched no purchasable SKU: the marketplace floor is 8 vCPU, so the largest thing this repo deployed by default (6 metered vCores) was smaller than the smallest thing a customer could buy. See [`docs/SKU_DEPLOYMENT_MATRIX.md`](docs/SKU_DEPLOYMENT_MATRIX.md).

  **Upgrade impact:** if you rely on the module defaults, the next `terraform apply` **replaces your instances** and roughly quadruples both the infrastructure bill and the metered licence (2 → 8 vCores per node). To keep existing sizing, pin `instance_type` / `vm_size` explicitly *before* upgrading — but note that a sub-8 node is supported only for phishing-simulation-only deployments.

- **`instance_type` / `vm_size` now reject off-ladder values at plan time.** New `validation` blocks constrain the HailBytes application node to the portable set — 2, 4, 8, 16, 32, 48, 64 vCores, mapped to `m6i.large`/`xlarge`/`2xlarge`/`4xlarge`/`8xlarge`/`12xlarge`/`16xlarge` and `Standard_B2s`/`D2s_v5`/`D4s_v5`/`D8s_v5`/`D16s_v5`/`D32s_v5`/`D48s_v5`/`D64s_v5`.

  *Why:* every rung is a stock general-purpose shape on **both** clouds at the same 4 GB-per-vCore ratio, so a deployment can move between clouds without changing tier. Critically, **neither Azure `Dsv5` nor AWS `m6i` has any general-purpose size between 16 and 32 vCPU**, so a 24-vCore deployment cannot be delivered as one VM *or* as a symmetric pair (2 × 12 does not exist either) — a `Standard_D24s_v5` now fails `terraform plan` with an explanation instead of being discovered at apply, or on an invoice.

  **Upgrade impact:** this is breaking for anyone passing a value outside that set — including the previous defaults `t3.large` (burstable T-family, not on the ladder) and any `m5.*` shape. Migrate to the equivalent `m6i` / `Dsv5` rung at the same vCPU count.

  Only the HailBytes application node is constrained. `db_instance_class`, `db_ec2_instance_type`, `db_vm_size` and `redis_node_type` remain free-form: they are cloud infrastructure, not HailBytes-licensed capacity, and they do not meter.

- **Auto-scaling baseline reduced from 3 nodes to 2** (`asg_min_size`, `asg_desired_capacity`, `vmss_min_count`). A fixed three-node steady state picked an arbitrary point on what is really a range of identical 8-vCore nodes. Two is the smallest baseline that survives a node loss, and it lines up with the HA pair at 16 metered vCores so the two shapes agree. `asg_max_size` / `vmss_max_count` are unchanged at 20. Combined with the size default, the autoscale baseline meters 16 vCores (2 × 8) instead of 6 (3 × 2).

### Added

- **`vm_names` and `db_vm_name` on the Azure HA tier**, so a customer's host-naming standard can govern the VM names outright. `name_prefix` sets every other resource, but the VMs are what a naming policy actually constrains, and `<prefix>-vm-1` cannot be coerced into `svc-web-P-01` through a prefix alone — the `-vm-N` suffix and the 1-based unpadded index are ours. `vm_names` takes exactly two names in zone order (element 0 → zone 1); `db_vm_name` names the self-managed Postgres VM in `db_mode = "vm"`. Both default to `null` and keep the derived names. Renaming an existing VM **replaces** it, which on a two-node pair applied in one go is a full outage — the variable description says so. Forwarded by `sat-azure-ha` and `asm-azure-ha`.

### Changed

- **The Azure preflight is now regional, and checks rather than advises.** `quickstart/preflight-azure.sh` takes `--location` (or `HB_LOCATION`, default `northeurope`) and adds three checks that were previously prose telling the operator to go and look:

  - **Marketplace image availability in that region**, printing the Active version and flagging every version scheduled for deprecation. Accepted terms and an available image are different things — terms are subscription-scoped, availability is regional — and the failure mode is a `terraform apply` that dies at the VM, after the vnet, the Key Vault and the database already exist.
  - **Availability zones for the application SKU.** The HA tier pins zones 1 and 2 and runs a ZoneRedundant Flexible Server; neither is optional and not every region has zones.
  - **Regional vCPU quota**, compared against what the tier will actually request rather than printed for the operator to compare themselves. Short quota now says how much is needed and how much is available.

  `preflight-aws.sh` gains the same needed-vs-available comparison, with the honest caveat that Service Quotas reports the limit and not current consumption, so it can only catch a limit that is too small outright.

  Every new check degrades to a readable "could not read this, here is the command" rather than failing the script — a preflight that exits 1 because the operator lacks subscription read is worse than one that says so.

  `preflight-azure.sh` is now exercised end to end as a subprocess against the mocked CLI in `quickstart/tests/cloud_prereqs_test.sh`, which it never was — only its provider arrays were compared. Nine new subprocess cases and six output assertions, including the three regional failures.

- **A stale claim removed from the preflight output.** It said that below 8 vCPUs "the product's own sizing advisory reports 'upsize' for training workloads". That behaviour changed in `hailbytes-sat`: the advisory now escalates on measured load rather than core count, so a deliberately small instance is not told to upsize while it has headroom.

### Fixed

- **The phishing surface shared the admin allow-list, so a correctly locked-down SAT deployment served nothing to its targets.** `allowed_cidrs` governed both the admin console (443 → `admin_port`) and the phishing/landing surface (80 → `phish_port`) on `ha-hot-hot/azure`, `single-vm/azure` and `single-vm/aws`. Those two surfaces have opposite audiences: the console is for operators on an office or VPN range, and the landing pages are for simulation targets, who are by definition somewhere else.

  With one list, an operator who locks the console to their egress range also locks every target out of the landing pages. The campaign still sends. The targets get a connection timeout, no open or click is recorded, and the deployment presents as a broken product rather than a firewall rule — the failure is silent on the operator's side, which is what makes it expensive.

  New `phish_allowed_cidrs` on all three tier modules and their six wrappers governs the phishing surface alone. It defaults to `null`, which inherits `allowed_cidrs` and reproduces the previous behaviour exactly, so **no existing deployment changes on the next apply**. `allow_internet_ingress` deliberately does not gate it: that flag guards the admin surface, and applying it here would silently strip the `0.0.0.0/0` a live simulation needs, re-coupling the two lists this variable exists to separate. Inert on ASM, which has no phishing surface. Regression tests in `modules/ha-hot-hot/azure/tests/feature_flags.tftest.hcl` assert the inheritance default, the independence of the two lists, and that opening the phishing surface does not widen the admin one.

  Not addressed here: `ha-hot-hot/aws` exposes no phishing surface at all — no ALB rule, no security-group rule — so SAT on the AWS HA tier serves no landing pages. That is a separate gap from this one and is not fixed by this change. Both it and the equivalent gap on `unlimited-scale` were closed in Unreleased.


- **Every tier but `ha-hot-hot` routed traffic to a port SAT does not listen on, and `ha-hot-hot` routed ASM's to a port ASM does not listen on.** The two products bind different ports — SAT serves its admin UI on **3333** (`config.json` `listen_url`, which the image's bootstrap banner prints verbatim as `https://<ip>:3333`) plus **80** for the phishing/landing surface, while ASM runs Django on `:8000` behind a proxy container that publishes **443**. Only `ha-hot-hot` had been corrected (#85, #87), and only for SAT.

  Consequences, all of which present as an application fault rather than a network one:

  - `single-vm/aws` and `single-vm/azure` opened **only 443**, with deny-all behind it. There is no load balancer in this tier to translate 443 to 3333, so a SAT single-VM deployment answered nothing on the address its own bootstrap banner told the operator to visit, and its landing pages — the product — were unreachable on 80.
  - `unlimited-scale/aws` and `unlimited-scale/azure` hardcoded 443 on the target group, its health check, and both sides of the ALB-to-instance hop (Azure: the LB rule, its probe, and the Application Gateway backend settings). A SAT autoscale deployment health-checked a port nothing binds, so the pool stayed empty and the frontend served 503 to everything.
  - `asm-aws-ha` and `asm-azure-ha` defaulted `admin_port = 3333` — SAT's port, inherited by the ASM wrappers. The load balancer probed and forwarded to a port no ASM node binds.

  `admin_port` and `phish_port` now default to `null` in all six tier modules and are **derived from `product`**: 3333/80 for SAT, 443 for ASM. The mapping lives in one place per tier rather than as a literal in each wrapper, because a wrapper carrying its own number is a wrapper that can silently drift from the image it deploys. All twelve wrappers forward both variables. `single-vm` also gained a separate SAT-only phishing rule, mirroring `ha-hot-hot`, so the phishing surface can be revoked independently of the admin surface.

  **Upgrade impact:** for SAT this **replaces security-group rules** on AWS (changing `from_port`/`to_port` forces replacement) and updates NSG rules in place on Azure; on the autoscale tier the target-group port change **replaces the target group**, and the ALB listener is updated to point at the new one. For ASM on `single-vm` and `unlimited-scale` the derived value is 443 and the plan is a no-op. Nothing about the public frontend port changes on any tier: 443 stays 443.

  `unlimited-scale` had **no phishing frontend at all** as of this release — no port-80 LB rule on Azure, and the AWS port-80 listener was an HTTPS redirect rather than the SAT landing surface. `phish_port` was declared there for surface parity but not wired, so SAT landing pages were not reachable through the autoscale tier. **Fixed in Unreleased** — see *`unlimited-scale` served no phishing landing pages on either cloud* above.

- **`ARCHITECTURE.md` and `SECURITY-DEFAULTS.md` described the ports the modules were supposed to open rather than the ones the products bind.** The `single-vm` diagram showed a browser reaching the VM on 443 with no load balancer in the path; the HA diagram still claimed health checks on `/health`, a path corrected to `/api/health` / `/api/ready` in #80. Both now name the real ports and probe paths per product.

- **Removed a committed merge-conflict marker from `CHANGELOG.md`.** A stray `<<<<<<< HEAD` on line 27 had no matching `=======` or `>>>>>>>` — a resolution that kept both sides and left the opening marker behind, rendering as literal text in the changelog.

- **The self-managed database node was wrongly counted as metered, over-stating the licence fee by ~$350/mo.** `COST_SHAPES.md`, `AZURE_COST_SHAPES.md`, `docs/AZURE_PATCHING_AND_MIGRATION.md`, `quickstart/README.md` and `quickstart/deploy.sh` all told customers that in `db_mode = "ec2"` / `"vm"` the database VM "runs the HailBytes image, so it carries the meter too", making that mode *cheaper infrastructure but a higher total*. It does not. `aws_instance.db_ec2` boots `data.aws_ami.ubuntu`, and `azurerm_linux_virtual_machine.db_vm` uses a `Canonical / ubuntu-24_04-lts` `source_image_reference` with **no `plan {}` block** — plain Ubuntu with apt-installed PostgreSQL 16. Only nodes running the HailBytes Marketplace image meter. The self-managed-DB shape is therefore cheaper infrastructure *and* a lower total; what it actually gives up is managed backups, PITR and automatic failover. Metered vCores for that shape drop from 6 to 4. (`docs/SKU_DEPLOYMENT_MATRIX.md` already had this right.)

- **32-vCore annual list corrected from $67,200 to $67,300, and the derivation convention with it.** Prices were computed as `round-to-nearest-$100(monthly) × 12`, which rounds *before* multiplying and so multiplies the rounding error twelvefold. It agreed with the meter up to 16 vCPU and drifted above: −$100 at 32 and 48 vCores, −$200 at 64 and 96, −$300 at 128. Annual list is now `round100(0.24 × vCores × 8760)` and monthly `round10(0.24 × vCores × 730)`, matching `hailbytes-sat/docs/VM_SCALING.md`. Restated in `COST_SHAPES.md` and `docs/SKU_DEPLOYMENT_MATRIX.md`.

- **`HB-STD` (12 vCores) and `HB-ENT` (24 vCores) withdrawn.** Neither size exists as a general-purpose shape on either cloud. `HB-STD` was previously fulfilled as 3 × `m6i.xlarge` — three 4-vCore nodes, each *below* the 8-vCore training floor — so it is withdrawn rather than re-mapped. **Neither code may be reused for a different vCore count**: a procurement system that bought `HB-ENT` as 24 vCores must not silently receive 32. `HB-ENTP` (32) is unchanged apart from its corrected price; `HB-ENTP-HA`, `HB-MSP` and `HB-MSP-L` are proposed codes pending commercial sign-off.

- **`HB-SCALE` no longer quoted at a fixed node count.** It was specified as 48 metered vCores at a 6 × 8 steady state. The autoscale shape is a range of identical 8-vCore nodes, so the meter is `8 × instance count`, quoted from the 2-node baseline upward.

- **`ARCHITECTURE.md` HA cost claim corrected from "~6× cost of single-vm" to ~2.8×**, matching `COST_SHAPES.md`. The *licence* is exactly 2× — the meter counts vCores, not machines — and the remainder is the added load balancer, Multi-AZ database and shared Redis. The failover description now distinguishes **N** (pair of the tier below the roster: meets it normally, half capacity during failover) from **N+1** (pair of the tier the roster needs: full capacity through a failover), instead of implying the surviving node always carries full load.

- **`docs/SKU_DEPLOYMENT_MATRIX.md`: the 8-vCore floor is per instance, not per deployment.** It previously stated "the 8 vCPU floor is per **deployment**, not per instance. 4 × 2 vCPU satisfies Essential." The *commercial* floor is per deployment; the *training* floor is per instance and is checked against `runtime.NumCPU()` on each node, so 4 × 2 vCPU does not satisfy it for anything serving training content.

- **CI `examples-validate` now covers the `HB-PRO-HA` / `HB-SCALE` simplified-SKU examples.** `modules/ha-hot-hot/aws/examples/hb-pro-ha` and `modules/unlimited-scale/aws/examples/hb-scale` exist on disk and are the canonical snippets `ha-hot-hot/aws/README.md`, `unlimited-scale/aws/README.md`, and `COST_SHAPES.md` point customers to for those two named catalog SKUs, but neither was ever added to the `examples-validate` matrix in `.github/workflows/ci.yml` — so a future variable/output rename could silently break the exact example these SKUs' customers are told to copy-paste, with CI staying green throughout. No drift found today; this closes the coverage gap before one occurs.

- **`ha-hot-hot/aws`: `db_mode = "ec2"` data volume now has an actual destroy guard** ([#65](https://github.com/HailBytes/hailbytes-terraform-modules/issues/65)). `aws_ebs_volume.db_data` previously set `prevent_destroy = false` — Terraform's own default, a no-op — regardless of `var.db_deletion_protection`, which only ever protected the `db_mode = "rds"` path. A `terraform destroy`, an accidental resource removal, or a forced replacement (e.g. changing `availability_zone`) would delete the self-managed Postgres data volume with no guard and no snapshot fallback (EBS has none, unlike RDS's `final_snapshot_identifier`). `prevent_destroy` is now hardcoded to `true` unconditionally — it cannot be wired to the variable since Terraform requires a literal there. `db_deletion_protection`'s description (in `ha-hot-hot/aws`, `asm-aws-ha`, `sat-aws-ha`) now states plainly that it governs the RDS path only; EC2-mode protection is separate and always on. No resource replacement for existing deployments — this only adds a destroy guard that was already assumed to exist.
- **`ha-hot-hot/azure`: HA application VMs now get an NSG** ([#51](https://github.com/HailBytes/hailbytes-terraform-modules/issues/51)). Previously, when `vm_subnet_id` differed from `lb_subnet_id`, the app VM subnet had zero inbound filtering from this module — contrary to `SECURITY-DEFAULTS.md`'s "NSGs default to deny all inbound" claim, and unlike every sibling tier (`single-vm/azure`, `unlimited-scale/azure`, `ha-hot-hot/aws`). Adds `azurerm_network_security_group.vm` (allow-443 per `allowed_cidrs` entry, mirroring the existing `lb` NSG) and associates it with `vm_subnet_id`, gated behind a new `associate_vm_subnet_nsg` variable (default `true`) for customers who already manage NSGs on that subnet. When `vm_subnet_id == lb_subnet_id` (the common case per the variable docs), no second NSG is created — a subnet can only have one associated NSG, and the existing `lb` NSG already covers it. New `vm_nsg_id` output; forwarded through `asm-azure-ha` and `sat-azure-ha`.
  **Security-posture change for existing deployments:** if you run `asm-azure-ha` or `sat-azure-ha` with `vm_subnet_id` distinct from `lb_subnet_id`, the next `apply` will associate a new NSG that filters that subnet to port 443 from `allowed_cidrs` only — traffic previously unfiltered (monitoring agents, management tooling, other intra-VNet callers on other ports) will be blocked unless it originates from `allowed_cidrs`. Review `allowed_cidrs` before upgrading, or set `associate_vm_subnet_nsg = false` to opt out and manage the NSG association yourself (the NSG resource is still created and exported via `vm_nsg_id`).
- **HA / autoscale wrappers re-export the full tier output surface.** All 8 product wrappers (`asm`/`sat` × `aws`/`azure` × `ha`/`autoscale`) were missing `post_patch_ssm_document_name` / `post_patch_run_command_name` / `post_patch_run_command_extension_name`, `redis_endpoint`, and `redis_mode` — outputs the patching runbook tells customers to read. Additive only; no resource changes.
- **`ha-hot-hot/aws`: EC2 snapshot IAM scoped to the DB data volume** (`db_mode = "ec2"` only). `ec2:CreateSnapshot` / `ec2:CreateTags` were granted on `Resource = "*"`, letting the self-managed Postgres instance snapshot any volume in the account. Now scoped to the module's data volume and `snapshot/*` ARNs with an `ec2:CreateAction` condition; `Describe*` keeps `*` (no resource-level support).
- **`ha-hot-hot/aws`: `db_backup_retention_days` description matches actual precedence.** The deprecated alias wins over `rds_backup_retention_period` when set (it always did, via `coalesce`); the description previously claimed the opposite.
- **Azure App Gateway inputs fail fast.** `ha-hot-hot/azure` and `unlimited-scale/azure` now validate via plan-time preconditions that `appgw_subnet_id` and the TLS PFX inputs are set when `enable_application_gateway = true`, instead of a cryptic apply-time provider error.
- **`unlimited-scale/azure`: VMSS waits for Postgres read replicas** (`depends_on` previously listed only the primary).
- **azurerm floor raised to `>= 4.0, < 5.0`** (all Azure modules), and the 3.x-era `enable_rbac_authorization` / storage container `resource_manager_id` usages renamed to their 4.x forms (`rbac_authorization_enabled`, container `id`). azurerm 4.x deprecates the old names and 5.x removes them; the 4.x names don't exist in 3.x, so this is a coordinated floor bump done before the first tagged release. No resource changes on apply.

- **Shared Redis is now provisioned by default in every HA / autoscale module.** Previously `ha-hot-hot/{aws,azure}` and `unlimited-scale/{aws,azure}` shipped two-or-more application instances behind a load balancer with no shared session store, which silently broke cross-instance login and the worker-lock heartbeat in production HA deployments. The new default is an ElastiCache (AWS, Multi-AZ) / Azure Cache for Redis (Standard or Premium, zone-redundant) replication group sized at the procurement-friendly tier (`cache.t4g.small` / `Standard C1`). The Azure modules reject the single-node `Basic` SKU at validation time so an unsafe SKU choice fails fast.
- **Pre-patch SSM / Run Command documents fail loud on a missing on-AMI script.** Previously the `if [ -x /opt/hailbytes/bin/ha-pre-patch-backup.sh ]; then ...; else WARN ...; fi` guard masked the case where the AMI was built before the Packer change that installs the script. Customers running an older AMI now see an explicit "rebuild the marketplace image from main" error instead of a silently no-op backup. Same change on Azure pre-patch. Applies to both `ha-hot-hot` and `unlimited-scale`.

### Testing

- **All 12 product wrapper modules now have `terraform test` coverage** ([#42](https://github.com/HailBytes/hailbytes-terraform-modules/issues/42)). Previously only the 10 tier/network modules had `.tftest.hcl` files; the wrappers — the actual public API customers instantiate — had none. Each wrapper's `tests/basic.tftest.hcl` mirrors its core module's mock-provider fixture and asserts every re-exported output is non-empty, including `redis_endpoint`, `redis_mode`, and the post-patch SSM/Run Command outputs that regressed silently in a prior release (see the "HA / autoscale wrappers re-export the full tier output surface" entry above). The `terraform-test` CI matrix now covers all 12 wrappers in addition to the 10 core modules.

### Documentation

- `docs/PATCHING_AND_MIGRATION.md` referenced a nonexistent `v1.1.0` tag; now `v1.0.0` like every other doc. **A `v1.0.0` git tag must be cut on `main` before customers can use any README quickstart** — every snippet pins `?ref=v1.0.0`.
- **README and `docs/PATCHING_AND_MIGRATION.md` now call out that no `v1.0.0` tag exists yet** ([#48](https://github.com/HailBytes/hailbytes-terraform-modules/issues/48)), so a customer copy-pasting a quickstart snippet sees a pin-to-commit-SHA workaround instead of a bare `terraform init` failure. Superseded by cutting the actual tag.
- HA / autoscale READMEs now say to edit `terraform.tfvars` (replacing the `REPLACE` placeholders) before `terraform apply`.
- `COST_SHAPES.md` labels the comparison table as procurement-grade sizing, not module defaults.
- **Azure HA / autoscale: TLS termination tradeoff called out in READMEs.** In the default Standard LB mode the frontend is TCP passthrough on 443, so the browser terminates against the VM's self-signed certificate — and the certificate CN (now the per-VM IMDS hostname after the corresponding `hailbytes-asm` / `hailbytes-sat` `setup.sh` change) does not match the LB public IP nor any DNS record customers point at it. Production deployments should set `enable_application_gateway = true` with a real PFX, or front the module with their own upstream L7 LB. No code change; this documents an existing behavior that was previously silent.

### Added

- **`ha-hot-hot/azure`: customer-managed-key disk encryption** (`enable_customer_managed_key`, default `false`, exposed on `asm-azure-ha` / `sat-azure-ha`). Creates an RSA-4096 key in the module's Key Vault plus a disk encryption set covering app VM OS/data disks and the self-managed Postgres VM's OS/data disks — closing the gap with the single-vm and unlimited-scale tiers.
- **Post-patch verifier SSM / Run Command documents** on every HA / autoscale module (AWS `aws_ssm_document.post_patch_verify`, Azure `azurerm_virtual_machine_run_command.post_patch_verify` / `azurerm_virtual_machine_scale_set_extension.post_patch_verify`). Invokes the on-AMI `/opt/hailbytes/bin/ha-post-patch-verify.sh` five-probe verifier so a rolling-replace can fail fast on a schema-version regression, encryption-key fingerprint mismatch, or worker-lock outage.
- **`COST_SHAPES.md`** at the repo root: single source of truth for the three deployment shapes (`single` / `ha-hot-hot` / `unlimited-scale`) on both AWS and Azure, with per-vCore meter as a first-class line and procurement-grade all-in totals. Anchors module READMEs to a single canonical price reference and an Azure-Cache-for-Redis sizing table.
- **Per-product wrapper modules now expose the full Redis surface** (`enable_managed_redis`, `redis_node_type` / `redis_sku_name`, `redis_endpoint_override`, etc.) plus `enable_post_patch_run_command` on Azure. Customers using `sat-aws-ha` / `asm-aws-ha` / etc. can override every variable the core module accepts.
- **CI suite** (`.github/workflows/ci.yml`, plus the standalone `checkov.yml` / `trivy-iac.yml` workflows): `terraform fmt -check`, `terraform validate` (22-module matrix), `tflint --recursive`, **`checkov`** (findings fail unless waived in `.checkov.yaml`) and **`trivy-iac`** (MEDIUM+ findings fail unless waived in `.trivyignore`) with SARIF upload to code-scanning, **examples validation** (matrix across `modules/*/{aws,azure}/examples/basic`), **marketplace-id consistency** (asserts every `marketplace_product_codes` use carries the canonical AWS AMI codes + Azure publisher/offer slugs), **wrapper variable forwarding** (diffs every wrapper's `variables.tf` against its core module — would have caught the Redis-vars-not-forwarded gap above), **versions.tf existence + `required_version` pin** check, and **`COST_SHAPES.md` sync** check.

### Migration notes (existing customers)

The next `terraform apply` against an upgraded module **will provision a managed Redis replication group** unless you set `enable_managed_redis = false` and supply `redis_endpoint_override`. This is the intended behaviour — a customer-visible deployment whose two SAT/ASM instances were not sharing session state was not actually highly-available, regardless of what the LB topology suggested. Expected plan output:

- **AWS HA / autoscale**: `+ aws_elasticache_replication_group.main`, `+ aws_elasticache_subnet_group.main`, `+ aws_security_group.redis`, `+ aws_vpc_security_group_ingress_rule.redis_from_vm`. Cost impact ≈ +$50/mo at the `cache.t4g.small` default.
- **Azure HA / autoscale**: `+ azurerm_redis_cache.main`. Cost impact ≈ +$55/mo at the `Standard C1` default.

VMs will be **replaced** on apply because `user_data` / `custom_data` now carries `redis_host` / `redis_port` / `redis_tls`. Schedule the apply during a maintenance window. RDS / Postgres / data volumes are untouched.

To preserve the previous behaviour (NOT recommended — silently breaks cross-instance sessions on HA), set `enable_managed_redis = false` and provide `redis_endpoint_override` to wire an existing customer-managed Redis. The HA module emits `redis_mode = "disabled"` when neither managed Redis nor an override is configured — a loud signal in `terraform output` that the deployment is not session-safe.

After applying, **rebuild the marketplace AMIs** from the corresponding application repos (`hailbytes-sat`, `hailbytes-asm`) on the same branch that ships the Packer change which installs `/opt/hailbytes/bin/ha-pre-patch-backup.sh` and `ha-post-patch-verify.sh`. The new pre-patch SSM doc fails loud on a stale AMI rather than silently no-op-ing the backup.

## [Unreleased — prior]

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
