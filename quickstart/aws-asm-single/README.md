# Quickstart: HailBytes ASM on AWS, single tier

One EC2 instance with a public IP and the database on board, in a VPC this config builds. No load balancer and no redundancy: a reboot is an outage, and the instance holds the only copy of your data. Pilots and small clients.

Everything deploys into **your** AWS account. No HailBytes access, no
phone-home. Software billing runs through your AWS Marketplace subscription at
$0.24/vCPU-hour; at the default sizing that is m6i.2xlarge (the module default, 8 vCPU). The AWS
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
cd hailbytes-terraform-modules/quickstart/aws-asm-single
export AWS_REGION=us-east-1
../preflight-aws.sh single
cp terraform.tfvars.example terraform.tfvars   # set allowed_cidrs (and region if not us-east-1)
../bootstrap-state-aws.sh --out . --region "$AWS_REGION" --key hailbytes-asm-single.tfstate
terraform init && terraform apply
```

## Verify and log in

```bash
curl -k "$(terraform output -raw console_url)api/ready"
eval "$(terraform output -raw initial_credentials_command)"
```

Log in as `admin` with the password it prints, then change it.

## Tearing down

Destroy needs three things first, all in
[Runbook Step 10](../../docs/AWS_MSSP_RUNBOOK.md#step-10-tear-it-down-with-terraform):
empty the object-locked backup bucket, and read the
destroy plan. Then:

```bash
terraform plan -destroy -out destroy.tfplan
terraform apply destroy.tfplan
```
