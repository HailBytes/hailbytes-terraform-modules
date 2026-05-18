# `unlimited-scale/aws`

Elastic deployment of HailBytes Marketplace VMs: Auto Scaling Group across 3 AZs, ALB, RDS PostgreSQL Multi-AZ + read replicas, CloudWatch alarms wired to SNS, VPC Flow Logs.

> [!IMPORTANT]
> **Marketplace subscription required.** Subscribe to [HailBytes ASM](https://aws.amazon.com/marketplace/pp/prodview-66d5bswmbtfhs) or [HailBytes SAT](https://aws.amazon.com/marketplace/pp/prodview-yyk6iton3ghu4) on AWS Marketplace before applying. Every instance the ASG launches is billed against your marketplace subscription.

## Architecture

```mermaid
flowchart TB
    User([Tenants / Operators]) -->|HTTPS 443| ALB[Application Load Balancer<br/>access logs to S3]
    ALB --> ASG[Auto Scaling Group<br/>min=3, max=20<br/>3 AZs<br/>TT on CPU + req/target]
    ASG --> VMn[(Marketplace AMI instances)]
    VMn -->|writes| DBP[(RDS PostgreSQL<br/>Multi-AZ primary)]
    VMn -->|reads| DBR1[(Read replica 1)]
    VMn -->|reads| DBR2[(Read replica 2)]
    VMn --> SM[(Secrets Manager<br/>DB creds)]
    VMn --> CW[CloudWatch<br/>metrics + agent logs]
    DBP --> CW
    ALB --> CW
    CW -.alarms.-> SNS[SNS topic\nemail subscription]
    VPC[VPC Flow Logs] --> CW
```

## Cost estimate (us-east-1, on-demand, default sizing)

Unlimited-scale is a fundamentally different cost shape from a single
instance: it adds an ASG, ALB, read replicas, ElastiCache, and the
per-vCore meter scales with N instances rather than the topology itself.
Compare against `modules/single-vm/aws` (~$84/mo infra + meter) and
`modules/ha-hot-hot/aws` (~$435-$515/mo infra + meter) before you quote.

| Component | Default | ~Monthly |
|---|---|---|
| 3× EC2 `m6i.large` (ASG min) | 24/7 | $225 |
| 3× EBS gp3 root | 50 GB | $12 |
| Application Load Balancer + LCU | | $35 |
| ElastiCache Redis Multi-AZ (`cache.t4g.small`) | shared session store | $50 |
| RDS `db.r6g.large` Multi-AZ primary | 200 GB gp3 | $400 |
| 2× RDS read replicas `db.r6g.large` | | $400 |
| RDS backups | 30d retention | $40 |
| S3 access logs | 90d, ~50 GB | $2 |
| CloudWatch logs + alarms | typical | $30 |
| KMS CMK | 1 + usage | $5 |
| Secrets Manager | 1 | $0.40 |
| SNS | low volume | $0.10 |
| **Total infrastructure (3-instance steady state)** | | **~$1,200/month** |
| **+ scale-out hours** | each extra m6i.large 24/7 | +$75/mo per instance |
| **HailBytes marketplace software fee** ($0.24/vCPU-hr) | 3× 2 vCPU × 730h | **~$1,050/mo** |
| **All-in (3-instance steady state)** | | **~$2,250/month** |

Scale-out adds both an EC2 line and a per-vCPU meter line for every
extra instance. At 5 steady-state instances the bill lands around
$2,950/mo all-in; at 10 instances around $4,700/mo all-in. For
deployments that routinely run above 5 instances, raise `redis_node_type`
to `cache.m6g.large` (~$120/mo) — t4g.small starts becoming a bottleneck
for shared-session throughput in that range.

## Prerequisites

- VPC with at least 2 public subnets (ALB) and 3 private subnets across different AZs
- ACM certificate in the same region
- Marketplace subscription active for the product
- IAM permissions for EC2, ASG, ALB, RDS, ElastiCache, IAM, KMS, S3, CloudWatch, SNS, Secrets Manager

## Usage

```hcl
module "hailbytes_asm_scale" {
  source = "github.com/hailbytes/hailbytes-terraform-modules//modules/unlimited-scale/aws?ref=v1.0.0"

  product             = "asm"
  environment         = "prod"
  vpc_id              = "vpc-xxxxxxxx"
  public_subnet_ids   = ["subnet-pub-a", "subnet-pub-b"]
  private_subnet_ids  = ["subnet-priv-a", "subnet-priv-b", "subnet-priv-c"]
  allowed_cidrs       = ["10.0.0.0/8"]
  acm_certificate_arn = "arn:aws:acm:us-east-1:...:certificate/..."
  alert_email         = "soc-oncall@example.com"

  asg_min_size            = 3
  asg_max_size            = 30
  db_read_replica_count   = 2
  db_backup_retention_days = 30
}
```

## Deployment

```bash
cd examples/basic
cp terraform.tfvars.example terraform.tfvars
terraform init && terraform apply
```

## Post-deploy verification

```bash
# 1. ASG launched min instances
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $(terraform output -raw autoscaling_group_name) --query 'AutoScalingGroups[0].Instances[*].[InstanceId,LifecycleState,HealthStatus]'

# 2. Targets healthy
TG_ARN=$(aws elbv2 describe-target-groups --names $(terraform output -raw autoscaling_group_name | sed 's/-asg/-tg/') --query 'TargetGroups[0].TargetGroupArn' -o text)
aws elbv2 describe-target-health --target-group-arn $TG_ARN

# 3. End-to-end health
curl https://$(terraform output -raw alb_dns_name)/health

# 4. Confirm read replicas in sync
for r in $(terraform output -json db_read_endpoints | jq -r '.[]'); do
  aws rds describe-db-instances --db-instance-identifier ${r%%.*} --query 'DBInstances[0].StatusInfos'
done
```

## Inputs / Outputs

See [`variables.tf`](variables.tf) and [`outputs.tf`](outputs.tf).
