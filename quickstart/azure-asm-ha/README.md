# Quickstart: HailBytes ASM on Azure, HA tier

> **Needs an ASM image with cluster mode.** This tier gives every node one
> managed database and a shared `asm-cluster-key` secret. ASM images built
> from HailBytes/hailbytes-asm#1734 onward read them and join one cluster
> (one database, one admin account, shared Hatchet). Older images ignore
> them and each node becomes a separate deployment behind one address, so
> until the Marketplace listing carries that image, use the single-VM tier.
> After deploying, `curl -s https://<address>/api/ready` a few times: every
> response should report the same `database_id`.

Two VMs across Availability Zones 1 and 2 behind a load balancer, a zone-redundant Postgres Flexible Server, and Key Vault. Like the SAT HA quickstart, this config builds the networking too.

The ASM twin of [`../azure-ha`](../azure-ha) (SAT). It differs in three
ways: the module is `asm-azure-ha` and the listing is
[HailBytes ASM](https://marketplace.microsoft.com/en-us/product/virtual-machines/lcmcon1687976613543.hardened_ubuntu_with_rengine);
there is no phishing surface, so there is no `phish_allowed_cidrs`; and the
console is on 443 with its health check at `/api/ready`.

Everything deploys into **your** subscription. No HailBytes access, no
phone-home. Software billing runs through your Azure Marketplace subscription
at $0.24/vCPU-hour.

Deploying for an MSSP client? Follow
[docs/AZURE_MSSP_RUNBOOK.md](../../docs/AZURE_MSSP_RUNBOOK.md) with
`PRODUCT=asm`. It covers per-client naming, state and teardown.

## Deploy

```bash
git clone https://github.com/hailbytes/hailbytes-terraform-modules
cd hailbytes-terraform-modules/quickstart/azure-asm-ha
../preflight-azure.sh ha --product asm --location northeurope
cp terraform.tfvars.example terraform.tfvars   # set allowed_cidrs and ssh_public_key
../bootstrap-state-azure.sh --out . --location northeurope --key hailbytes-asm-ha.tfstate
terraform init && terraform apply
```

The preflight checks quota for Standard_D2s_v3. Pass `--vm-size` if you set `vm_size`.

## Verify and log in

```bash
curl -k "$(terraform output -raw console_url)api/ready"
eval "$(terraform output -raw initial_credentials_command)"
```

Log in as `admin` with the password it prints (`DJANGO_SUPERUSER_PASSWORD`),
then change it. It reads the password from each node in turn; use the first one that works.

## Tearing down

```bash
terraform plan -destroy -out destroy.tfplan   # read it: everything should be in one resource group
terraform apply destroy.tfplan
```

[Runbook Step 10](../../docs/AZURE_MSSP_RUNBOOK.md#step-10-tear-it-down-with-terraform)
covers exporting data first, lifting delete locks, keeping other deployments'
Marketplace terms intact, and what deliberately survives.
