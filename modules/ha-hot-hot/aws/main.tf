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
}

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
    host     = aws_db_instance.main.address
    port     = aws_db_instance.main.port
    dbname   = aws_db_instance.main.db_name
  })
}

# ----- RDS -----

resource "aws_db_subnet_group" "main" {
  name       = "${local.name_prefix}-db-subnets"
  subnet_ids = var.private_subnet_ids
  tags       = local.common_tags
}

resource "aws_db_parameter_group" "main" {
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
  parameter_group_name   = aws_db_parameter_group.main.name
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]

  multi_az                = true
  backup_retention_period = var.db_backup_retention_days
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = !var.db_deletion_protection
  final_snapshot_identifier = var.db_deletion_protection ? "${local.name_prefix}-final-${formatdate("YYYYMMDD-hhmmss", timestamp())}" : null
  copy_tags_to_snapshot     = true

  performance_insights_enabled    = true
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  auto_minor_version_upgrade      = true

  tags = local.common_tags

  lifecycle {
    ignore_changes = [final_snapshot_identifier, password]
  }
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
      db_secret_arn      = aws_secretsmanager_secret.db.arn
      db_secret_region   = data.aws_region.current.id
      product            = var.product
      cluster_member_idx = count.index
    }
  }))

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-vm-${count.index + 1}" })

  lifecycle {
    ignore_changes = [ami, user_data]
  }

  depends_on = [aws_db_instance.main]
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
