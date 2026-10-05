# Quickstart: HailBytes SAT on AWS, autoscale tier

An Auto Scaling group behind an Application Load Balancer, RDS PostgreSQL, ElastiCache for shared sessions, and the VPC around them. One shared instance for many clients, or one very large client. Every running instance meters, so `asg_max_size` caps the software bill.

SAT has two surfaces: the admin console and the phishing landing pages. Set `phish_allowed_cidrs` (usually `["0.0.0.0/0"]`) or the landing pages are reachable only from your admin range, and campaigns record no clicks.

Everything deploys into **your** AWS account. No HailBytes access, no
phone-home. Software billing runs through your AWS Marketplace subscription at
$0.24/vCPU-hour; at the default sizing that is m6i.large × 2 to 4 (2 vCPU each). The AWS
infrastructure is billed separately by AWS.

Deploying for an MSSP client? Follow
[docs/AWS_MSSP_RUNBOOK.md](../../docs/AWS_MSSP_RUNBOOK.md). It covers per-client
naming, state and teardown, for both products and all three tiers.

## Deploy

Subscribe to [HailBytes SAT on AWS Marketplace](https://aws.amazon.com/marketplace/pp/prodview-yyk6iton3ghu4) first. Terraform
cannot subscribe for you, and an unsubscribed product fails the apply with
`OptInRequired` when the instance is launched.

```bash
git clone https://github.com/hailbytes/hailbytes-terraform-modules
cd hailbytes-terraform-modules/quickstart/aws-sat-autoscale
export AWS_REGION=us-east-1
../preflight-aws.sh autoscale
cp terraform.tfvars.example terraform.tfvars   # set allowed_cidrs (and region if not us-east-1)
../bootstrap-state-aws.sh --out . --region "$AWS_REGION" --key hailbytes-sat-autoscale.tfstate
terraform init && terraform apply
```

On the first deploy the load balancer serves a self-signed certificate this
config generates, so browsers warn. Supply `acm_certificate_arn` for the
client's hostname to replace it.

## Verify and log in

```bash
curl -k "$(terraform output -raw console_url)api/health"
eval "$(terraform output -raw initial_credentials_command)"
```

Log in as `admin` with the password it prints, then change it.

## Tearing down

Destroy needs three things first, all in
[Runbook Step 10](../../docs/AWS_MSSP_RUNBOOK.md#step-10-tear-it-down-with-terraform):
turn off `deletion_protection` in its own apply, empty the object-locked backup bucket and the access-log bucket, and read the
destroy plan. Then:

```bash
terraform plan -destroy -out destroy.tfplan
terraform apply destroy.tfplan
```
