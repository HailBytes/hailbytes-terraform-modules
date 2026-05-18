locals {
  name_prefix = coalesce(var.name_prefix, "hailbytes-${var.product}-${var.environment}")

  # AWS Marketplace listings (subscribe before applying):
  #   ASM: https://aws.amazon.com/marketplace/pp/prodview-66d5bswmbtfhs
  #   SAT: https://aws.amazon.com/marketplace/pp/prodview-yyk6iton3ghu4
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
      Module      = "hailbytes-terraform-modules/ha-hot-hot/aws"
    },
    var.tags,
  )

  # Pick two private subnets for two VMs (one per AZ). For >2 subnets we take the first 2.
  vm_subnets = slice(var.private_subnet_ids, 0, 2)

  use_rds                 = var.db_mode == "rds"
  use_ec2_db              = var.db_mode == "ec2"
  create_backup_bucket    = var.create_backup_bucket
  effective_backup_bucket = local.create_backup_bucket ? aws_s3_bucket.backup[0].id : var.backup_bucket_name
  backup_object_prefix    = "hailbytes-${var.product}-"

  db_host = coalesce(one(aws_db_instance.main[*].address), one(aws_instance.db_ec2[*].private_ip))
  db_port = local.use_rds ? coalesce(one(aws_db_instance.main[*].port), 5432) : 5432
  db_arn  = coalesce(one(aws_db_instance.main[*].arn), one(aws_instance.db_ec2[*].arn))
  db_id   = coalesce(one(aws_db_instance.main[*].id), one(aws_instance.db_ec2[*].id))
}

data "aws_caller_identity" "current" {}

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
}

# ----- KMS -----

resource "aws_kms_key" "main" {
  count                   = var.enable_customer_managed_key ? 1 : 0
  description             = "KMS key for ${local.name_prefix} (EBS, RDS, Secrets)"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = local.common_tags
}

# ----- Security groups -----

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "ALB ingress"
  vpc_id      = var.vpc_id
  tags        = local.common_tags
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = toset(var.allowed_cidrs)

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS from ${each.value}"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http_redirect" {
  for_each = var.enable_http_redirect ? toset(var.allowed_cidrs) : toset([])

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "HTTP (redirected to HTTPS) from ${each.value}"
}

resource "aws_vpc_security_group_egress_rule" "alb_out" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.vm.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "ALB to VM 443"
}

resource "aws_security_group" "vm" {
  name        = "${local.name_prefix}-vm-sg"
  description = "VM ingress from ALB"
  vpc_id      = var.vpc_id
  tags        = local.common_tags
}

resource "aws_vpc_security_group_ingress_rule" "vm_from_alb" {
  security_group_id            = aws_security_group.vm.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "HTTPS from ALB"
}

resource "aws_vpc_security_group_egress_rule" "vm_out" {
  security_group_id = aws_security_group.vm.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Egress for marketplace metering, updates, DB"
}

resource "aws_security_group" "db" {
  name        = "${local.name_prefix}-db-sg"
  description = "Postgres ingress from VMs"
  vpc_id      = var.vpc_id
  tags        = local.common_tags
}

resource "aws_vpc_security_group_ingress_rule" "db_from_vm" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.vm.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "Postgres from VMs"
}

# ----- IAM -----

resource "aws_iam_role" "vm" {
  name = "${local.name_prefix}-vm-role"
  tags = local.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  count      = var.enable_management_access ? 1 : 0
  role       = aws_iam_role.vm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "secrets" {
  name = "${local.name_prefix}-read-db-secret"
  role = aws_iam_role.vm.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = aws_secretsmanager_secret.db.arn
    }]
  })
}

resource "aws_iam_instance_profile" "vm" {
  name = "${local.name_prefix}-vm-profile"
  role = aws_iam_role.vm.name
  tags = local.common_tags
}

# ----- DB credentials -----

resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!@#$%^&*()-_=+[]{}"
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${local.name_prefix}-db-credentials"
  description             = "HailBytes ${var.product} Postgres master credentials"
  kms_key_id              = var.enable_customer_managed_key ? aws_kms_key.main[0].arn : null
  recovery_window_in_days = 7
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = "hailbytes"
    password = random_password.db.result
    host     = local.db_host
    port     = local.db_port
    dbname   = "hailbytes"
    mode     = var.db_mode
  })
}

# ----- DB: RDS Multi-AZ mode (default) -----
#
# RDS Multi-AZ is the default and recommended production database. Customers
# who must keep all data plane on EC2 (compliance, simplification, or a
# Bring-Your-Own-DBA preference) can flip var.db_mode = "ec2" and the module
# provisions a self-managed Postgres on a third EC2 instead. See
# docs/PATCHING_AND_MIGRATION.md for the trade-offs.

resource "aws_db_subnet_group" "main" {
  count      = local.use_rds ? 1 : 0
  name       = "${local.name_prefix}-db-subnets"
  subnet_ids = var.private_subnet_ids
  tags       = local.common_tags
}

resource "aws_db_parameter_group" "main" {
  count  = local.use_rds ? 1 : 0
  name   = "${local.name_prefix}-pg16"
  family = "postgres16"
  tags   = local.common_tags

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  # Log queries slower than 1s for triage; rotates through CloudWatch.
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }
}

resource "aws_db_instance" "main" {
  count          = local.use_rds ? 1 : 0
  identifier     = "${local.name_prefix}-db"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage_gb
  max_allocated_storage = var.db_max_allocated_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.enable_customer_managed_key ? aws_kms_key.main[0].arn : null

  db_name                = "hailbytes"
  username               = "hailbytes"
  password               = random_password.db.result
  port                   = 5432
  parameter_group_name   = aws_db_parameter_group.main[0].name
  db_subnet_group_name   = aws_db_subnet_group.main[0].name
  vpc_security_group_ids = [aws_security_group.db.id]

  multi_az                = true
  backup_retention_period = coalesce(var.db_backup_retention_days, var.rds_backup_retention_period)
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = !var.db_deletion_protection
  final_snapshot_identifier = var.db_deletion_protection ? "${local.name_prefix}-final-${formatdate("YYYYMMDD-hhmmss", timestamp())}" : null
  copy_tags_to_snapshot     = var.rds_copy_tags_to_snapshot

  performance_insights_enabled    = true
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  auto_minor_version_upgrade      = true

  tags = local.common_tags

  lifecycle {
    ignore_changes = [final_snapshot_identifier, password]
  }
}

# ----- DB: self-managed Postgres on EC2 mode (var.db_mode = "ec2") -----
#
# Provisions a third EC2 with stock Ubuntu 24.04 and apt-installs PostgreSQL 16
# via cloud-init. Storage lives on an encrypted gp3 data volume; password is
# the same random_password the RDS path uses, so the secret format is
# identical and the marketplace VM bootstraps with no branching. There are no
# HailBytes binaries on this VM — it is pure infrastructure.

data "aws_ami" "ubuntu" {
  count       = local.use_ec2_db ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
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

resource "aws_iam_role_policy" "db_ec2_backup" {
  count = local.use_ec2_db ? 1 : 0
  name  = "${local.name_prefix}-db-ec2-backup"
  role  = aws_iam_role.db_ec2[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = aws_secretsmanager_secret.db.arn
      },
      {
        Effect = "Allow"
        Action = ["ec2:CreateSnapshot", "ec2:CreateTags", "ec2:DescribeVolumes", "ec2:DescribeSnapshots"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role" "db_ec2" {
  count = local.use_ec2_db ? 1 : 0
  name  = "${local.name_prefix}-db-ec2-role"
  tags  = local.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "db_ec2_ssm" {
  count      = local.use_ec2_db ? 1 : 0
  role       = aws_iam_role.db_ec2[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "db_ec2" {
  count = local.use_ec2_db ? 1 : 0
  name  = "${local.name_prefix}-db-ec2-profile"
  role  = aws_iam_role.db_ec2[0].name
  tags  = local.common_tags
}

resource "aws_ebs_volume" "db_data" {
  count             = local.use_ec2_db ? 1 : 0
  availability_zone = data.aws_subnet.db[0].availability_zone
  size              = var.db_ec2_data_volume_size_gb
  type              = "gp3"
  iops              = 3000
  throughput        = 250
  encrypted         = true
  kms_key_id        = var.enable_customer_managed_key ? aws_kms_key.main[0].arn : null
  tags              = merge(local.common_tags, { Name = "${local.name_prefix}-db-data" })

  lifecycle {
    prevent_destroy = false
  }
}

data "aws_subnet" "db" {
  count = local.use_ec2_db ? 1 : 0
  id    = var.private_subnet_ids[0]
}

resource "aws_instance" "db_ec2" {
  count = local.use_ec2_db ? 1 : 0

  ami                    = data.aws_ami.ubuntu[0].id
  instance_type          = var.db_ec2_instance_type
  subnet_id              = var.private_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.db.id]
  iam_instance_profile   = aws_iam_instance_profile.db_ec2[0].name
  ebs_optimized          = true
  monitoring             = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    kms_key_id            = var.enable_customer_managed_key ? aws_kms_key.main[0].arn : null
    delete_on_termination = true
  }

  # cloud-init: install Postgres 16, format the attached EBS volume as XFS,
  # mount at /var/lib/postgresql/16/main, initdb, configure TLS + scram-sha-256
  # auth scoped to the DB subnet's CIDR, and seed the hailbytes user/database
  # from the password in Secrets Manager. The marketplace SAT/ASM image needs
  # no special handling — it sees the same Secrets Manager secret shape as in
  # RDS mode.
  user_data_replace_on_change = false
  user_data = <<-EOF
    #cloud-config
    package_update: true
    packages:
      - postgresql-16
      - postgresql-contrib-16
      - xfsprogs
      - python3
      - awscli
      - jq
    write_files:
      - path: /usr/local/sbin/hailbytes-init-postgres.sh
        permissions: '0700'
        owner: root:root
        content: |
          #!/bin/bash
          set -euo pipefail
          REGION=${data.aws_region.current.id}
          SECRET_ARN=${aws_secretsmanager_secret.db.arn}
          DB_CIDR=${data.aws_subnet.db[0].cidr_block}

          # Resolve the attached data volume by elimination: the only "disk"-type
          # block device that is not the root and not currently mounted.
          for _ in $(seq 1 60); do
            DEV=$(lsblk -nrpo NAME,TYPE,MOUNTPOINT,PKNAME | awk '$2=="disk" && $3=="" {print "/dev/"$1; exit}')
            if [ -n "$DEV" ]; then break; fi
            sleep 2
          done
          : "$${DEV:?data volume did not attach within 120 seconds}"
          if ! blkid "$DEV" >/dev/null 2>&1; then
            mkfs.xfs "$DEV"
          fi
          mkdir -p /var/lib/postgresql/16/main
          UUID=$(blkid -s UUID -o value "$DEV")
          grep -q "$$UUID" /etc/fstab || echo "UUID=$$UUID /var/lib/postgresql/16/main xfs defaults,nofail 0 2" >> /etc/fstab
          mountpoint -q /var/lib/postgresql/16/main || mount /var/lib/postgresql/16/main
          chown -R postgres:postgres /var/lib/postgresql

          systemctl stop postgresql || true
          if [ ! -s /var/lib/postgresql/16/main/PG_VERSION ]; then
            sudo -u postgres /usr/lib/postgresql/16/bin/initdb -D /var/lib/postgresql/16/main
          fi
          CONF=/etc/postgresql/16/main/postgresql.conf
          HBA=/etc/postgresql/16/main/pg_hba.conf
          grep -q "^listen_addresses" "$CONF" || echo "listen_addresses = '*'" >> "$CONF"
          grep -q "^ssl = on"          "$CONF" || echo "ssl = on"             >> "$CONF"
          grep -q "^password_encryption" "$CONF" || echo "password_encryption = scram-sha-256" >> "$CONF"
          grep -q "host hailbytes hailbytes $$DB_CIDR scram-sha-256" "$HBA" \
            || echo "host hailbytes hailbytes $$DB_CIDR scram-sha-256" >> "$HBA"
          systemctl enable postgresql
          systemctl start postgresql

          PW=$(aws --region "$REGION" secretsmanager get-secret-value --secret-id "$SECRET_ARN" \
                | jq -r '.SecretString | fromjson | .password')
          sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='hailbytes'" | grep -q 1 \
            || sudo -u postgres psql -c "CREATE USER hailbytes WITH PASSWORD '$$PW';"
          sudo -u postgres psql -c "ALTER USER hailbytes WITH PASSWORD '$$PW';"
          sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='hailbytes'" | grep -q 1 \
            || sudo -u postgres psql -c "CREATE DATABASE hailbytes OWNER hailbytes;"
    runcmd:
      - /usr/local/sbin/hailbytes-init-postgres.sh
  EOF

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-db" })

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

resource "aws_volume_attachment" "db_data" {
  count       = local.use_ec2_db ? 1 : 0
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.db_data[0].id
  instance_id = aws_instance.db_ec2[0].id
}

# ----- VMs (one per AZ, active/active) -----

resource "aws_instance" "vm" {
  count = length(local.vm_subnets)

  ami                    = data.aws_ami.hailbytes.id
  instance_type          = var.instance_type
  subnet_id              = local.vm_subnets[count.index]
  vpc_security_group_ids = [aws_security_group.vm.id]
  iam_instance_profile   = aws_iam_instance_profile.vm.name
  key_name               = var.key_name
  ebs_optimized          = true
  monitoring             = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 50
    encrypted             = true
    kms_key_id            = var.enable_customer_managed_key ? aws_kms_key.main[0].arn : null
    delete_on_termination = true
  }

  ebs_block_device {
    device_name = "/dev/sdh"
    volume_type = "gp3"
    volume_size = var.data_volume_size_gb
    encrypted   = true
    kms_key_id  = var.enable_customer_managed_key ? aws_kms_key.main[0].arn : null
  }

  # The marketplace image reads these on first boot to wire itself to the shared DB.
  # Values are not sensitive (they reference the secret ARN, not the password).
  user_data = base64encode(jsonencode({
    hailbytes = {
      mode               = "ha"
      db_mode            = var.db_mode
      db_secret_arn      = aws_secretsmanager_secret.db.arn
      db_secret_region   = data.aws_region.current.id
      product            = var.product
      cluster_member_idx = count.index
    }
  }))

  tags = merge(local.common_tags, {
    Name             = "${local.name_prefix}-vm-${count.index + 1}"
    "hailbytes-${var.product}" = "true"
  })

  lifecycle {
    ignore_changes = [ami, user_data]
  }

  depends_on = [aws_db_instance.main, aws_instance.db_ec2]
}

data "aws_region" "current" {}

# ----- ALB -----

resource "aws_lb" "main" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids
  idle_timeout       = var.alb_idle_timeout_seconds

  drop_invalid_header_fields = true
  enable_http2               = true

  tags = local.common_tags
}

resource "aws_lb_target_group" "main" {
  name        = "${local.name_prefix}-tg"
  port        = 443
  protocol    = "HTTPS"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    enabled             = true
    protocol            = "HTTPS"
    path                = "/health"
    port                = "443"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 15
  }

  stickiness {
    type            = "lb_cookie"
    cookie_duration = 3600
    enabled         = true
  }

  tags = local.common_tags
}

resource "aws_lb_target_group_attachment" "vm" {
  count = length(aws_instance.vm)

  target_group_arn = aws_lb_target_group.main.arn
  target_id        = aws_instance.vm[count.index].id
  port             = 443
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.alb_min_tls_version
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  count = var.enable_http_redirect ? 1 : 0

  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# ----- Optional WAF attachment -----

resource "aws_wafv2_web_acl_association" "alb" {
  count        = var.waf_web_acl_arn == null ? 0 : 1
  resource_arn = aws_lb.main.arn
  web_acl_arn  = var.waf_web_acl_arn
}

# ----- SNS topic for patching alerts -----

resource "aws_sns_topic" "alerts" {
  name              = "${local.name_prefix}-alerts"
  kms_master_key_id = var.enable_customer_managed_key ? aws_kms_key.main[0].id : "alias/aws/sns"
  tags              = local.common_tags
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email == null ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ----- CloudWatch alarms (runbook tripwires) -----
#
# These mirror the autoscale module's refresh alarms so the same procurement
# runbook applies: a customer-initiated taint-and-apply on a single VM at a
# time keeps capacity at 50% via Terraform create_before_destroy lifecycle,
# and these alarms detect collateral damage. ASG Instance Refresh is not
# available on this tier (2x standalone EC2, not an ASG); see
# docs/PATCHING_AND_MIGRATION.md for the runbook.

resource "aws_cloudwatch_metric_alarm" "alb_5xx_rate" {
  alarm_name          = "${local.name_prefix}-alb-5xx-rate"
  alarm_description   = "Target group 5xx rate > ${var.refresh_rollback_5xx_threshold_pct}% over 2 minutes."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = var.refresh_rollback_5xx_threshold_pct
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  metric_query {
    id          = "rate"
    expression  = "100 * (m5xx + IF(b5xx, b5xx, 0)) / IF(req, req, 1)"
    label       = "5xx percent of total requests"
    return_data = true
  }

  metric_query {
    id = "req"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = aws_lb.main.arn_suffix
        TargetGroup  = aws_lb_target_group.main.arn_suffix
      }
    }
  }

  metric_query {
    id = "m5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = aws_lb.main.arn_suffix
        TargetGroup  = aws_lb_target_group.main.arn_suffix
      }
    }
  }

  metric_query {
    id = "b5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_ELB_5XX_Count"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = aws_lb.main.arn_suffix
      }
    }
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  alarm_name          = "${local.name_prefix}-unhealthy-targets"
  alarm_description   = "Target group has unhealthy hosts for 3 minutes; expected to fire only during a rolling patch."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.main.arn_suffix
  }

  tags = local.common_tags
}

# ----- Backup S3 bucket -----

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
      kms_master_key_id = var.enable_customer_managed_key ? aws_kms_key.main[0].arn : null
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

# ----- SSM Run Command document: pre-patch backup -----

resource "aws_ssm_document" "pre_patch_backup" {
  name            = "${local.name_prefix}-pre-patch-backup"
  document_type   = "Command"
  document_format = "YAML"
  target_type     = "/AWS::EC2::Instance"
  tags            = local.common_tags

  content = yamlencode({
    schemaVersion = "2.2"
    description   = "HailBytes SAT/ASM pre-patch backup. Bundles DB + uploads + manifest to the configured S3 bucket and triggers an RDS snapshot (RDS mode) or EBS snapshot (EC2 mode)."
    parameters = {
      bucketName = {
        type        = "String"
        description = "S3 bucket name. Defaults to the module-provisioned bucket."
        default     = local.effective_backup_bucket == null ? "" : local.effective_backup_bucket
      }
      snapshotIdentifier = {
        type        = "String"
        description = "Optional override for the DB snapshot identifier; defaults to a timestamped value."
        default     = ""
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
            "export HAILBYTES_DB_SECRET_ARN='${aws_secretsmanager_secret.db.arn}'",
            "export AWS_DEFAULT_REGION='${data.aws_region.current.id}'",
            "if [ -x /opt/hailbytes/bin/ha-pre-patch-backup.sh ]; then sudo -E /opt/hailbytes/bin/ha-pre-patch-backup.sh; else echo 'WARN: /opt/hailbytes/bin/ha-pre-patch-backup.sh not present on this AMI; skipping local bundle.'; fi",
            "SNAP_ID='{{ snapshotIdentifier }}'",
            "if [ -z \"$SNAP_ID\" ]; then SNAP_ID=\"${local.name_prefix}-pre-patch-$${TS}\"; fi",
            "if [ '${var.db_mode}' = 'rds' ]; then aws rds create-db-snapshot --db-instance-identifier '${try(aws_db_instance.main[0].id, "")}' --db-snapshot-identifier \"$SNAP_ID\" --tags Key=Module,Value=hailbytes-terraform-modules Key=Phase,Value=pre-patch; else VOL='${try(aws_ebs_volume.db_data[0].id, "")}'; if [ -n \"$VOL\" ]; then aws ec2 create-snapshot --volume-id \"$VOL\" --description \"hailbytes-${var.product} pre-patch $${TS}\" --tag-specifications \"ResourceType=snapshot,Tags=[{Key=Module,Value=hailbytes-terraform-modules},{Key=Phase,Value=pre-patch},{Key=Name,Value=$$SNAP_ID}]\"; fi; fi",
          ]
        }
      }
    ]
  })
}
