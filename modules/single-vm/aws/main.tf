locals {
  name_prefix = coalesce(var.name_prefix, "hailbytes-${var.product}-${var.environment}")

  # AWS Marketplace listings (subscribe at these URLs before applying):
  #   ASM: https://aws.amazon.com/marketplace/pp/prodview-66d5bswmbtfhs
  #   SAT: https://aws.amazon.com/marketplace/pp/prodview-yyk6iton3ghu4
  # Product codes were obtained with:
  #   aws ec2 describe-images --owners aws-marketplace \
  #     --filters 'Name=name,Values=hailbytes-<product>-*' \
  #     --query 'Images[*].ProductCodes'
  marketplace_product_codes = {
    asm = "1n57wg1f6735e30vj5fn420bp"
    sat = "d19hjbz3gakqdlonlf8twdmll"
  }

  ami_name_pattern = {
    asm = "hailbytes-asm-*"
    sat = "hailbytes-sat-*"
  }

  effective_product_code = coalesce(var.marketplace_product_code, local.marketplace_product_codes[var.product])

  common_tags = merge(
    {
      Name        = local.name_prefix
      Product     = "hailbytes-${var.product}"
      Environment = var.environment
      ManagedBy   = "terraform"
      Module      = "hailbytes-terraform-modules/single-vm/aws"
    },
    var.tags,
  )

  ingress_cidrs = var.allow_internet_ingress ? var.allowed_cidrs : [
    for c in var.allowed_cidrs : c if c != "0.0.0.0/0"
  ]

  create_backup_bucket    = var.create_backup_bucket
  effective_backup_bucket = local.create_backup_bucket ? aws_s3_bucket.backup[0].id : var.backup_bucket_name
  backup_object_prefix    = "hailbytes-${var.product}-"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ----- Marketplace AMI lookup -----
#
# Resolves the latest published version of the HailBytes Marketplace image for the
# requested product. Will fail with NotFoundException if the account has not
# accepted the marketplace subscription — this is the intended failure mode and
# the signal to the operator to subscribe at the marketplace URL.

data "aws_ami" "hailbytes" {
  most_recent = true
  owners      = ["aws-marketplace"]

  filter {
    name   = "product-code"
    values = [local.effective_product_code]
  }

  filter {
    name   = "name"
    values = [local.ami_name_pattern[var.product]]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ----- KMS (optional customer-managed key) -----

resource "aws_kms_key" "ebs" {
  count = var.enable_customer_managed_key ? 1 : 0

  description             = "EBS encryption key for ${local.name_prefix}"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = local.common_tags
}

resource "aws_kms_alias" "ebs" {
  count         = var.enable_customer_managed_key ? 1 : 0
  name          = "alias/${local.name_prefix}-ebs"
  target_key_id = aws_kms_key.ebs[0].key_id
}

# ----- Network: security group -----

resource "aws_security_group" "vm" {
  name        = "${local.name_prefix}-sg"
  description = "HailBytes ${var.product} single-vm ingress and egress"
  vpc_id      = var.vpc_id
  tags        = local.common_tags
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  for_each = toset(local.ingress_cidrs)

  security_group_id = aws_security_group.vm.id
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS from ${each.value}"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.vm.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Egress to anywhere (marketplace metering, updates, integrations)"
}

# ----- IAM: instance profile -----

resource "aws_iam_role" "vm" {
  name = "${local.name_prefix}-role"
  tags = local.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  count      = var.enable_management_access ? 1 : 0
  role       = aws_iam_role.vm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "vm" {
  name = "${local.name_prefix}-profile"
  role = aws_iam_role.vm.name
  tags = local.common_tags
}

# ----- EC2 instance -----

resource "aws_instance" "vm" {
  ami                         = data.aws_ami.hailbytes.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.vm.id]
  iam_instance_profile        = aws_iam_instance_profile.vm.name
  key_name                    = var.key_name
  associate_public_ip_address = var.associate_public_ip
  ebs_optimized               = true
  monitoring                  = true
  tags = merge(local.common_tags, {
    "hailbytes-${var.product}" = "true"
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    kms_key_id            = var.enable_customer_managed_key ? aws_kms_key.ebs[0].arn : null
    delete_on_termination = true
    tags                  = merge(local.common_tags, { Name = "${local.name_prefix}-root" })
  }

  lifecycle {
    ignore_changes = [ami] # rotate images via explicit upgrade, not on every plan
  }
}

resource "aws_ebs_volume" "data" {
  availability_zone = aws_instance.vm.availability_zone
  size              = var.data_volume_size_gb
  type              = "gp3"
  encrypted         = true
  kms_key_id        = var.enable_customer_managed_key ? aws_kms_key.ebs[0].arn : null
  tags              = merge(local.common_tags, { Name = "${local.name_prefix}-data" })
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.vm.id
}

# ----- Snapshot lifecycle (optional) -----

resource "aws_iam_role" "dlm" {
  count = var.enable_snapshots ? 1 : 0
  name  = "${local.name_prefix}-dlm"
  tags  = local.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dlm" {
  count      = var.enable_snapshots ? 1 : 0
  role       = aws_iam_role.dlm[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "snapshots" {
  count = var.enable_snapshots ? 1 : 0

  description        = "${local.name_prefix} daily snapshots"
  execution_role_arn = aws_iam_role.dlm[0].arn
  state              = "ENABLED"
  tags               = local.common_tags

  policy_details {
    resource_types = ["VOLUME"]

    target_tags = {
      Name = "${local.name_prefix}-data"
    }

    schedule {
      name = "daily"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["03:00"]
      }

      retain_rule {
        count = 7
      }

      copy_tags = true
    }
  }
}

# ----- Patching and migration safety -----
#
# Backup bucket + SSM Run Command document mirror the HA and autoscale tiers
# so single-vm operators get the same procurement-grade pre-patch safety net
# (versioned, immutable S3 bundle with object-lock + lifecycle tiering, and a
# customer-initiated SSM doc that fires the on-VM ha-pre-patch-backup.sh).

resource "aws_s3_bucket" "backup" {
  count               = local.create_backup_bucket ? 1 : 0
  bucket              = coalesce(var.backup_bucket_name, "${local.name_prefix}-backups-${data.aws_caller_identity.current.account_id}")
  force_destroy       = false
  object_lock_enabled = true
  tags                = local.common_tags
}

resource "aws_s3_bucket_versioning" "backup" {
  count  = local.create_backup_bucket ? 1 : 0
  bucket = aws_s3_bucket.backup[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  count                   = local.create_backup_bucket ? 1 : 0
  bucket                  = aws_s3_bucket.backup[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  count  = local.create_backup_bucket ? 1 : 0
  bucket = aws_s3_bucket.backup[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.enable_customer_managed_key ? "aws:kms" : "AES256"
      kms_master_key_id = var.enable_customer_managed_key ? aws_kms_key.ebs[0].arn : null
    }
    bucket_key_enabled = var.enable_customer_managed_key
  }
}

resource "aws_s3_bucket_object_lock_configuration" "backup" {
  count  = local.create_backup_bucket ? 1 : 0
  bucket = aws_s3_bucket.backup[0].id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = var.backup_object_lock_retention_days
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  count  = local.create_backup_bucket ? 1 : 0
  bucket = aws_s3_bucket.backup[0].id

  rule {
    id     = "tier-and-expire"
    status = "Enabled"
    filter {
      prefix = local.backup_object_prefix
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "DEEP_ARCHIVE"
    }

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"
    }

    noncurrent_version_transition {
      noncurrent_days = 90
      storage_class   = "DEEP_ARCHIVE"
    }

    noncurrent_version_expiration {
      noncurrent_days = var.backup_noncurrent_version_expiration_days
    }
  }
}

resource "aws_iam_role_policy" "backup_put" {
  count = local.effective_backup_bucket == null ? 0 : 1
  name  = "${local.name_prefix}-backup-put"
  role  = aws_iam_role.vm.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl",
          "s3:AbortMultipartUpload",
        ]
        Resource = "arn:aws:s3:::${local.effective_backup_bucket}/${local.backup_object_prefix}*.tar.gz"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = "arn:aws:s3:::${local.effective_backup_bucket}"
      },
    ]
  })
}

resource "aws_ssm_document" "pre_patch_backup" {
  name            = "${local.name_prefix}-pre-patch-backup"
  document_type   = "Command"
  document_format = "YAML"
  target_type     = "/AWS::EC2::Instance"
  tags            = local.common_tags

  content = yamlencode({
    schemaVersion = "2.2"
    description   = "HailBytes SAT/ASM pre-patch backup. Bundles DB + uploads + manifest to the configured S3 bucket and snapshots the EBS data volume."
    parameters = {
      bucketName = {
        type        = "String"
        description = "S3 bucket name. Defaults to the module-provisioned bucket."
        default     = local.effective_backup_bucket == null ? "" : local.effective_backup_bucket
      }
    }
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "prePatchBackup"
        inputs = {
          timeoutSeconds = "1800"
          runCommand = [
            "set -euo pipefail",
            "TS=$(date -u +%Y-%m-%dT%H-%M-%SZ)",
            "BUCKET='{{ bucketName }}'",
            "if [ -n \"$BUCKET\" ]; then export AWS_S3_BUCKET=\"$BUCKET\"; fi",
            "export AWS_S3_PREFIX=\"${local.backup_object_prefix}$${TS}\"",
            "export AWS_DEFAULT_REGION='${data.aws_region.current.id}'",
            "if [ -x /opt/hailbytes/bin/ha-pre-patch-backup.sh ]; then sudo -E /opt/hailbytes/bin/ha-pre-patch-backup.sh; else echo 'WARN: /opt/hailbytes/bin/ha-pre-patch-backup.sh not present on this AMI; skipping local bundle.'; fi",
            "aws ec2 create-snapshot --volume-id '${aws_ebs_volume.data.id}' --description \"hailbytes-${var.product} pre-patch $${TS}\" --tag-specifications \"ResourceType=snapshot,Tags=[{Key=Module,Value=hailbytes-terraform-modules},{Key=Phase,Value=pre-patch},{Key=Name,Value=${local.name_prefix}-pre-patch-$${TS}}]\"",
          ]
        }
      }
    ]
  })
}
