# HailBytes SAT and ASM on AWS: the MSSP runbook

Stand up HailBytes SAT or HailBytes ASM for a client on AWS, run it, and tear
it down again, with Terraform, one numbered step at a time. Every command is
copy-paste. Each step says what it does, what to check before moving on, and
what to do when it goes wrong.

It is the AWS twin of [AZURE_MSSP_RUNBOOK.md](AZURE_MSSP_RUNBOOK.md) and
follows the same ten steps. The Azure runbook was written from live customer
deployments. This one carries the same structure over and is built from the
AWS modules' own behaviour, but **no customer deployment of these AWS
quickstarts has been watched end to end yet**. Treat your first client as the
shakedown.

> One deployment per client. Each client gets its own VPC, its own database,
> its own secrets and its own Terraform state, so tearing one down cannot touch
> another. If you would rather run several clients on one shared instance,
> that is a product decision (branding and SSO are instance-wide), covered on
> [hailbytes.com/for-mssps](https://hailbytes.com/for-mssps/#topologies). The
> steps below are the same either way. A shared instance is one deployment
> with your own name as `customer`.

---

## Before you start: three decisions

### Decision 1. Whose AWS account?

| | **A. Your account** | **B. The client's account** |
|---|---|---|
| Who pays AWS | You, then you re-bill | The client, directly |
| Marketplace subscription | Yours, once per product | The client's, once per product (or a CPPO private offer you arrange) |
| Who runs `terraform apply` | You | You, through a role in their account that trusts yours |
| Terraform state | One bucket per region for all your clients, one key per client (Step 4) | A bucket in their account |
| Data residency evidence | Your CloudTrail | The client's own CloudTrail |

Both use the same steps. Where a step differs, it says **(A)** or **(B)**.

### Decision 2. Which product?

**SAT** (phishing simulation and training) or **ASM** (attack surface
management). Where they differ it says **(SAT)** or **(ASM)**: SAT has a second,
public surface for the phishing landing pages; ASM has none.

### Decision 3. Which tier?

| Tier | SAT quickstart | ASM quickstart | Application nodes | Database | Use when |
|---|---|---|---|---|---|
| Single | [`aws-sat-single`](../quickstart/aws-sat-single) | [`aws-asm-single`](../quickstart/aws-asm-single) | 1, with a public IP | PostgreSQL on the instance | Pilots, small clients. A reboot is an outage, and the public IP changes if the instance is stopped and started. |
| HA hot-hot | [`aws-sat-ha`](../quickstart/aws-sat-ha) | [`aws-asm-ha`](../quickstart/aws-asm-ha) | 2, in two AZs, behind an ALB | RDS PostgreSQL | Production for most clients. |
| Autoscale | [`aws-sat-autoscale`](../quickstart/aws-sat-autoscale) | [`aws-asm-autoscale`](../quickstart/aws-asm-autoscale) | 2 to `asg_max_size`, behind an ALB | RDS PostgreSQL, Multi-AZ, optional read replicas | One shared instance carrying many clients, or one very large client. |

The software meter is $0.24 per vCPU-hour on every instance running the
HailBytes AMI, billed through AWS Marketplace. AWS infrastructure is billed
separately on the same account. [`COST_SHAPES.md`](../COST_SHAPES.md) has the
shapes side by side.

**Sizing differs from Azure.** The single and HA quickstarts keep the module
default, `m6i.2xlarge` (8 vCPU per instance, so 16 metered vCPU for an HA
pair). The autoscale quickstart uses `m6i.large` (2 vCPU). Set `instance_type`
from measured load.

Set four shell variables for the rest of the runbook. Everything below reads them:

```bash
export CUSTOMER=acme          # 2-16 chars: lowercase letters, digits, hyphens
export PRODUCT=sat            # sat | asm
export TIER=ha                # single | ha | autoscale
export AWS_REGION=us-east-1   # the client's region
QS=aws-$PRODUCT-$TIER         # the quickstart directory
```

---

## Step 1. Sign in, and point at the right account

Use [AWS CloudShell](https://console.aws.amazon.com/cloudshell) or a
workstation with the AWS CLI.

```bash
aws sts get-caller-identity              # the account you are about to deploy into
terraform version || echo "install Terraform (below)"
```

Terraform 1.10 or newer is needed for the state locking in Step 4. If
CloudShell has none, install it into your home directory, which persists
between sessions:

```bash
TFV=1.13.3; mkdir -p ~/bin && cd /tmp && curl -fsSLo tf.zip \
  "https://releases.hashicorp.com/terraform/${TFV}/terraform_${TFV}_linux_amd64.zip" \
  && unzip -o tf.zip -d ~/bin && export PATH="$HOME/bin:$PATH" && cd - && terraform version
```

**(B) the client's account.** The client creates a role in their account that
trusts yours, with the permissions the preflight lists in Step 2. You assume
it. Nothing is stored and HailBytes never sees it:

```bash
aws configure set profile.$CUSTOMER.role_arn arn:aws:iam::<client-account-id>:role/<role-name>
aws configure set profile.$CUSTOMER.source_profile default
export AWS_PROFILE=$CUSTOMER
aws sts get-caller-identity              # must now show the client's account
```

**Check before moving on:** `aws sts get-caller-identity` names the account
you mean. Everything after this lands in it.

## Step 2. Account prep: once per account and region, not per client

1. Subscribe to the product on AWS Marketplace, signed in to this account:
   [SAT](https://aws.amazon.com/marketplace/pp/prodview-yyk6iton3ghu4) or
   [ASM](https://aws.amazon.com/marketplace/pp/prodview-66d5bswmbtfhs).
   Terraform cannot subscribe for you. An unsubscribed account fails the apply
   with `OptInRequired` when the first instance launches, after the network
   and database already exist.
2. Run the preflight. It creates the service-linked roles RDS, ElastiCache,
   ELB and Auto Scaling need, then reports four things: whether the AMI is
   published in the region, the vCPU limit for the size you will run, Elastic
   IP and VPC headroom, and the IAM permissions the deploying identity needs.

```bash
git clone --depth 1 https://github.com/HailBytes/hailbytes-terraform-modules ~/hailbytes-terraform-modules
~/hailbytes-terraform-modules/quickstart/preflight-aws.sh "$TIER"
# autoscale: add --max-count <ceiling>. Any tier: add --instance-type <type> if you will set instance_type.
```

**Check before moving on:** read the output, not just the exit code. Two
things matter most:

- **Elastic IPs.** HA and autoscale use two each (a NAT gateway per AZ). The
  default limit is five per region, so a third client in the same region
  fails with `AddressLimitExceeded` unless you request more first.
- **The subscription.** A visible AMI does not prove you are subscribed;
  Marketplace AMIs are visible to everyone. Check the listing page says you
  are subscribed.

## Step 3. Give the client their own working directory

```bash
git clone --depth 1 https://github.com/HailBytes/hailbytes-terraform-modules ~/hailbytes/"$CUSTOMER"
cd ~/hailbytes/"$CUSTOMER"/quickstart/"$QS"
```

Keep the directory, or at least its `terraform.tfvars` and `backend.tf`, in
your own version control. Step 10 needs them.

## Step 4. Durable Terraform state

```bash
../bootstrap-state-aws.sh --out . --region "$AWS_REGION" --key "clients/$CUSTOMER/$PRODUCT-$TIER.tfstate"
```

The first run in an account and region creates the bucket
`hailbytes-tfstate-<account>-<region>`: versioned, encrypted, public access
blocked, TLS only. Every later client in the same account and region reuses
it automatically; only the key differs. State also holds the quickstart's
self-signed TLS key and generated passwords, which is why it does not stay
in CloudShell's home directory.

**Check before moving on:** `backend.tf` exists and names
`clients/<customer>/...` as its key.

## Step 5. Fill in terraform.tfvars

```bash
cp terraform.tfvars.example terraform.tfvars
```

Then set, at minimum:

```hcl
customer      = "acme"               # same as $CUSTOMER. Set it now: changing it later replaces everything
region        = "us-east-1"          # same as $AWS_REGION
allowed_cidrs = ["203.0.113.0/24"]   # who may reach the ADMIN console: your SOC, the client's admins
```

**(SAT)** also set who may reach the phishing landing pages, which is usually
everyone, because the targets are:

```hcl
phish_allowed_cidrs = ["0.0.0.0/0"]
```

What `customer` does:

- Names every resource `<customer>-<product>-<environment>-...`. IAM role names
  are account-wide and S3 names global, so two clients on the default names
  collide. Load-balancer names are capped at 32 characters, so the plan
  refuses a prefix over 26. Shorten `customer` or `environment` if it does.
- Tags every resource `customer=<customer>`, through the provider's
  `default_tags`. To split the bill by client, **activate `customer` as a cost
  allocation tag** once in the Billing console (Cost allocation tags). Until
  then, Cost Explorer cannot filter on it.

**Autoscale:** also review `instance_type`, `asg_min_size`, `asg_max_size` and
`db_read_replica_count`. Every running instance meters, so `asg_max_size` is
the ceiling on the software bill.

## Step 6. Plan, read the plan, apply

```bash
terraform init
terraform plan -out tfplan
```

Read the plan before applying it. Every name should start with
`<customer>-<product>-`, and nothing should be planned for destroy on a first
apply. Then:

```bash
terraform apply tfplan 2>&1 | tee apply.log
```

**If it fails,** do not re-run blindly and do not change names to get past it:

```bash
../explain.sh apply.log
```

It names the cause, who can fix it, and the exact command. Re-running the same
apply after the fix is safe.

## Step 7. Verify, and log in for the first time

Every quickstart has the same two outputs for this:

```bash
URL=$(terraform output -raw console_url)
HEALTH=api/health; [ "$PRODUCT" = asm ] && HEALTH=api/ready
curl -k "${URL}${HEALTH}"                 # expect HTTP 200; allow a few minutes after apply
eval "$(terraform output -raw initial_credentials_command)"
```

The second command prints the first-boot admin password:

- **SAT HA:** from Secrets Manager. Both instances share it, so it prints one
  value.
- **Everywhere else:** it reads the password off each instance in turn,
  through SSM Run Command. That means the single instance, every ASM
  deployment, and both products' autoscale tier. An instance takes a few
  minutes after boot to register with SSM; if it says the instance is not
  ready, wait and re-run. On autoscale the instances do not yet share one
  password, so log in with the first one that works.

Browse to the console URL, log in as `admin`, and change the password. HA and
autoscale serve the self-signed certificate this root generated until Step 8,
so expect a browser warning.

## Step 8. DNS, a trusted certificate, and (SAT) mail delivery

**DNS (HA and autoscale).** The console is the load balancer's DNS name
(`terraform output -raw console_url`). An ALB has no fixed IP, so point the
client's hostname at it with a CNAME, or a Route 53 alias record if the zone
is in Route 53. It does not change for the life of the deployment.

**DNS (single).** The console is the instance's public IP, which AWS
reassigns if the instance is stopped and started (a reboot keeps it). If the
client needs a stable hostname, use the HA tier.

**TLS (HA and autoscale).** Replace the self-signed certificate with an ACM
certificate for the client's hostname:

```bash
ARN=$(aws acm request-certificate --region "$AWS_REGION" --domain-name console.client.example \
        --validation-method DNS --query CertificateArn --output text)
aws acm describe-certificate --region "$AWS_REGION" --certificate-arn "$ARN" \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord'   # create this CNAME in the client's DNS
aws acm wait certificate-validated --region "$AWS_REGION" --certificate-arn "$ARN"
```

Then set `acm_certificate_arn = "<ARN>"` in `terraform.tfvars` and apply. The
listener moves to the new certificate and the self-signed one is removed.

**(SAT) Mail delivery.** Simulations land only if the client's mail filtering
lets them. [`quickstart/allowlisting`](../quickstart/allowlisting) scripts the
Exchange Online side. [`DELIVERABILITY_CHECKLIST.md`](DELIVERABILITY_CHECKLIST.md)
covers the rest. Third-party filtering gateways often accept an allow-list
request only from their customer, so ask the client to raise it in week one.

## Step 9. Hand over and operate

- **Secrets.** The database password (and on HA the shared session keys and
  first-boot admin password) are in Secrets Manager under
  `<customer>-<product>-<env>-*`.
  Grant your operators `secretsmanager:GetSecretValue` on those, rather than
  sharing the deploying identity.
- **Patching.** HailBytes publishes new AMIs to the Marketplace; you decide when
  to roll them. See [PATCHING_AND_MIGRATION.md](PATCHING_AND_MIGRATION.md).
- **Production safety.** `deletion_protection` is on by default (HA and
  autoscale). Leave it on.
- **Per-client cost.** Cost Explorer, filtered by tag `customer`, once the tag
  is activated (Step 5).
- **Record keeping.** Keep the working directory from Step 3. Its `backend.tf`
  is the only pointer to this client's state.

## Step 10. Tear it down with Terraform

Run this from the client's working directory (Step 3), signed in to the same
account (Step 1).

**1. Take what you need first.** Destroy deletes the database, and once
deletion protection is off, **it takes no final snapshot**. Lifting protection
also turns off the final snapshot (the modules tie the two together), and RDS
deletes its automated backups with the instance. The export is the only copy
you will have.

```bash
URL=$(terraform output -raw console_url)
AUTH="Bearer"; [ "$PRODUCT" = asm ] && AUTH="Token"
curl -kf -H "Authorization: $AUTH <admin API key>" "${URL}api/instance/export" -o "$CUSTOMER-export.tar.gz"
terraform output -raw backup_bucket_name; echo
terraform output -raw alb_access_logs_bucket 2>/dev/null; echo   # autoscale only
```

**2. Lift deletion protection in its own apply** (HA and autoscale):

```bash
terraform apply -var deletion_protection=false
```

**3. Empty the buckets destroy cannot delete.** The backup bucket is
Object-Locked and not force-destroyed, by design, and autoscale's access-log
bucket fills from the first request. Each needs every object version gone.
Deleting from the backup bucket needs `s3:BypassGovernanceRetention`.

```bash
../empty-bucket-aws.sh "$(terraform output -raw backup_bucket_name)" --region "$AWS_REGION"
../empty-bucket-aws.sh "$(terraform output -raw alb_access_logs_bucket)" --region "$AWS_REGION"   # autoscale only
```

It refuses any bucket without a `Product=hailbytes-*` tag and asks you to type
the name.

**4. Read the destroy plan, then destroy.**

```bash
terraform plan -destroy -out destroy.tfplan
terraform show destroy.tfplan | grep -E '^\s+# .* will be destroyed'
terraform apply destroy.tfplan 2>&1 | tee destroy.log
```

Everything listed should start with `<customer>-<product>-`. If destroy stops
partway, run the last two commands again; it picks up where it stopped. If
it fails the same way twice, run `../explain.sh destroy.log`.

**5. Confirm nothing is left billing.**

```bash
aws resourcegroupstaggingapi get-resources --region "$AWS_REGION" \
  --tag-filters "Key=customer,Values=$CUSTOMER" --query 'ResourceTagMappingList[].ResourceARN'
```

Expect nothing, apart from KMS keys and secrets still in their deletion
windows (below). The tagging API can lag by a few minutes.

**6. Clean up the state file**, once you are sure the client is not coming back:

```bash
aws s3 rm "s3://hailbytes-tfstate-$(aws sts get-caller-identity --query Account --output text)-${AWS_REGION}/clients/$CUSTOMER/$PRODUCT-$TIER.tfstate"
```

Leave the bucket itself alone. Your other clients' state lives in it.

### What deliberately survives a destroy

| What | Why | What to do |
|---|---|---|
| Secrets Manager **secrets** | Scheduled for deletion with a 7-day recovery window | Nothing, unless you rebuild the same client within 7 days: the apply then fails with `already scheduled for deletion`. Delete them for good with `aws secretsmanager delete-secret --force-delete-without-recovery --secret-id <name>`, or use another `environment`. |
| KMS **keys** (where a customer-managed key is on) | Pending deletion for 30 days | Nothing. Aliases are freed at once, so a rebuild does not collide. |
| The **state bucket** | Shared by every client in the account and region | Delete only the client's key (point 6). |
| The Marketplace **subscription** | Account-wide, not owned by Terraform | Leave it. Other clients depend on it. |

---

## What carries over from the Azure deployments

None of these is an AWS field report yet. Each is a failure the Azure
deployments hit, or the AWS modules make likely, with what handles it here.

| Risk | Where it is handled |
|---|---|
| Quota discovered halfway through an apply | The preflight sizes the vCPU check for the instance type and count you will run, and reports Elastic IP and VPC headroom (Step 2) |
| Two clients colliding on generated names | `customer` prefixes everything; the plan refuses prefixes too long for a load balancer (Step 5) |
| Terraform state lost with a shell session | Remote state before the first apply (Step 4) |
| Simulation targets locked out of the landing pages | Separate `phish_allowed_cidrs` (Step 5, SAT) |
| No human able to read the database password | Secrets Manager, with access granted to operators rather than the deploying identity (Step 9) |
| A protected database or a non-empty bucket stopping destroy halfway | Step 10 lifts protection and empties the buckets first, and `explain.sh` recognises both errors |
| A same-name rebuild failing on secrets still in their recovery window | Step 10's survivors table, and `explain.sh` |
| A third-party mail gateway accepting an allow-list request only from its customer | Step 8, so it starts in week one |
