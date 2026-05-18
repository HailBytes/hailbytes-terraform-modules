locals {
  name_prefix = coalesce(var.name_prefix, "hailbytes-${var.product}-${var.environment}")

  # HailBytes Marketplace product codes. These identify the paid listing in AWS Marketplace
  # and are how `data.aws_ami` finds the latest published image version.
  # Replace placeholder values once the marketplace listing IDs are assigned.
  marketplace_product_codes = {
    asm = "REPLACE_WITH_HAILBYTES_ASM_PRODUCT_CODE"
    sat = "REPLACE_WITH_HAILBYTES_SAT_PRODUCT_CODE"
  }

  ami_name_pattern = {
    asm = "hailbytes-asm-*"
    sat = "hailbytes-sat-*"
  }

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
}

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
    values = [local.marketplace_product_codes[var.product]]
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
  tags                        = local.common_tags

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
