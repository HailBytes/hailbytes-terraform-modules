# Quickstart: HailBytes ASM on AWS, ha tier

> **Needs an ASM image with cluster mode.** This tier gives every node one
> managed database and a shared `asm-cluster-key` secret. ASM images built
> from HailBytes/hailbytes-asm#1734 onward read them and join one cluster
> (one database, one admin account, shared Hatchet). Older images ignore
> them and each node becomes a separate deployment behind one address, so
> until the Marketplace listing carries that image, use the single-VM tier.
> After deploying, `curl -s https://<address>/api/ready` a few times: every
> response should report the same `database_id`.

Two EC2 instances across two Availability Zones behind an Application Load Balancer, RDS PostgreSQL, Secrets Manager, and the VPC around them. Production for most clients.

Everything deploys into **your** AWS account. No HailBytes access, no
phone-home. Software billing runs through your AWS Marketplace subscription at
$0.24/vCPU-hour; at the default sizing that is 2 × m6i.2xlarge (the module default, 16 vCPU in total). The AWS
infrastructure is billed separately by AWS.

Deploying for an MSSP client? Follow
[docs/AWS_MSSP_RUNBOOK.md](../../docs/AWS_MSSP_RUNBOOK.md). It covers per-client
naming, state and teardown, for both products and all three tiers.

## Deploy

Subscribe to [HailBytes ASM on AWS Marketplace](https://aws.amazon.com/marketplace/pp/prodview-66d5bswmbtfhs) first. Terraform
cannot subscribe for you, and an unsubscribed product fails the apply with
`OptInRequired` when the instance is launched.

```bash
git clone https://github.com/hailbytes/hailbytes-terraform-modules
cd hailbytes-terraform-modules/quickstart/aws-asm-ha
export AWS_REGION=us-east-1
../preflight-aws.sh ha
cp terraform.tfvars.example terraform.tfvars   # set allowed_cidrs (and region if not us-east-1)
../bootstrap-state-aws.sh --out . --region "$AWS_REGION" --key hailbytes-asm-ha.tfstate
terraform init && terraform apply
```

On the first deploy the load balancer serves a self-signed certificate this
config generates, so browsers warn. Supply `acm_certificate_arn` for the
client's hostname to replace it.

## Verify and log in

```bash
curl -k "$(terraform output -raw console_url)api/ready"
eval "$(terraform output -raw initial_credentials_command)"
```

Log in as `admin` with the password it prints, then change it.

## Tearing down

Destroy needs three things first, all in
[Runbook Step 10](../../docs/AWS_MSSP_RUNBOOK.md#step-10-tear-it-down-with-terraform):
turn off `deletion_protection` in its own apply, empty the object-locked backup bucket, and read the
destroy plan. Then:

```bash
terraform plan -destroy -out destroy.tfplan
terraform apply destroy.tfplan
```
