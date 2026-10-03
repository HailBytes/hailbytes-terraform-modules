# Quickstart: HailBytes ASM on Azure, single-VM tier

One VM with its own public IP and the database on board. No load balancer and no redundancy: a reboot is an outage, and the VM holds the only copy of your scan history.

The ASM twin of [`../azure-single`](../azure-single) (SAT). It differs in three
ways: the module is `asm-azure-single` and the listing is
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
cd hailbytes-terraform-modules/quickstart/azure-asm-single
../preflight-azure.sh single --product asm --location northeurope
cp terraform.tfvars.example terraform.tfvars   # set allowed_cidrs and ssh_public_key
../bootstrap-state-azure.sh --out . --location northeurope --key hailbytes-asm-single.tfstate
terraform init && terraform apply
```

The preflight checks quota for Standard_D4s_v5 (the module default, which draws the DSv5 quota pool). Pass `--vm-size` if you set `vm_size`.

## Verify and log in

```bash
curl -k "$(terraform output -raw console_url)api/ready"
eval "$(terraform output -raw initial_credentials_command)"
```

Log in as `admin` with the password it prints (`DJANGO_SUPERUSER_PASSWORD`),
then change it.

## Tearing down

```bash
terraform plan -destroy -out destroy.tfplan   # read it: everything should be in one resource group
terraform apply destroy.tfplan
```

[Runbook Step 10](../../docs/AZURE_MSSP_RUNBOOK.md#step-10-tear-it-down-with-terraform)
covers exporting data first, lifting delete locks, keeping other deployments'
Marketplace terms intact, and what deliberately survives.
