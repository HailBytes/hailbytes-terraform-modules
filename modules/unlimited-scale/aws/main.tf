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
      Module      = "hailbytes-terraform-modules/unlimited-scale/aws"
    },
    var.tags,
  )

  # Shared session store: required by every horizontally-scaled SAT/ASM
  # deployment because every ASG instance has to read the same session map
  # and worker-lock heartbeat. Provisioned by default; can be overridden.
  provision_managed_redis = var.enable_managed_redis && var.redis_endpoint_override == null
  effective_redis_host    = local.provision_managed_redis ? one(aws_elasticache_replication_group.main[*].primary_endpoint_address) : var.redis_endpoint_override
  effective_redis_port    = local.provision_managed_redis ? 6379 : var.redis_endpoint_override_port
}

data "aws_region" "current" {}
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
  description             = "${local.name_prefix} CMK for EBS, RDS, Secrets, S3 logs"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = local.common_tags
}

resource "aws_kms_alias" "main" {
  count         = var.enable_customer_managed_key ? 1 : 0
  name          = "alias/${local.name_prefix}"
  target_key_id = aws_kms_key.main[0].key_id
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

resource "aws_vpc_security_group_egress_rule" "alb_to_vm" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.vm.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "vm" {
  name        = "${local.name_prefix}-vm-sg"
  description = "ASG instance ingress from ALB"
  vpc_id      = var.vpc_id
  tags        = local.common_tags
}

resource "aws_vpc_security_group_ingress_rule" "vm_from_alb" {
  security_group_id            = aws_security_group.vm.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "vm_egress" {
  security_group_id = aws_security_group.vm.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
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
}

resource "aws_security_group" "redis" {
  count       = local.provision_managed_redis ? 1 : 0
  name        = "${local.name_prefix}-redis-sg"
  description = "ElastiCache Redis ingress from VMs (shared session store)"
  vpc_id      = var.vpc_id
  tags        = local.common_tags
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_vm" {
  count                        = local.provision_managed_redis ? 1 : 0
  security_group_id            = aws_security_group.redis[0].id
  referenced_security_group_id = aws_security_group.vm.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}

# ----- Shared session store: ElastiCache for Redis (Multi-AZ) -----
#
# Required for horizontal scaling. Every instance in the ASG must share session
# state, otherwise sticky-session ALB stickiness becomes the only thing keeping
# users logged in across rolling refresh.

resource "aws_elasticache_subnet_group" "main" {
  count      = local.provision_managed_redis ? 1 : 0
  name       = "${local.name_prefix}-redis-subnets"
  subnet_ids = var.private_subnet_ids
  tags       = local.common_tags
}

resource "aws_elasticache_replication_group" "main" {
  count                      = local.provision_managed_redis ? 1 : 0
  replication_group_id       = "${local.name_prefix}-redis"
  description                = "HailBytes ${var.product} session store + worker lock (scale-out)"
  engine                     = "redis"
  engine_version             = var.redis_engine_version
  node_type                  = var.redis_node_type
  num_cache_clusters         = 2
  automatic_failover_enabled = true
  multi_az_enabled           = true
  port                       = 6379
  parameter_group_name       = "default.redis7"
  subnet_group_name          = aws_elasticache_subnet_group.main[0].name
  security_group_ids         = [aws_security_group.redis[0].id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  kms_key_id                 = var.enable_customer_managed_key ? aws_kms_key.main[0].arn : null
  snapshot_retention_limit   = var.redis_snapshot_retention_days
  apply_immediately          = false
  tags                       = local.common_tags
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
  role       = aws_iam_role.vm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.vm.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy" "secrets" {
  name = "${local.name_prefix}-read-secrets"
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
  override_special = "!@#$%^&*()-_=+"
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${local.name_prefix}-db-credentials"
  kms_key_id              = var.enable_customer_managed_key ? aws_kms_key.main[0].arn : null
  recovery_window_in_days = 7
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username   = "hailbytes"
    password   = random_password.db.result
    host       = aws_db_instance.primary.address
    port       = aws_db_instance.primary.port
    dbname     = aws_db_instance.primary.db_name
    read_hosts = aws_db_instance.replica[*].address
  })
}

# ----- RDS primary + read replicas -----

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

  # Log queries slower than 1s for triage.
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }
}

resource "aws_db_instance" "primary" {
  identifier     = "${local.name_prefix}-db"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage_gb
  max_allocated_storage = var.db_max_allocated_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.enable_customer_managed_key ? aws_kms_key.main[0].arn : null

  db_name              = "hailbytes"
  username             = "hailbytes"
  password             = random_password.db.result
  port                 = 5432
  parameter_group_name = aws_db_parameter_group.main.name
  db_subnet_group_name = aws_db_subnet_group.main.name

  vpc_security_group_ids = [aws_security_group.db.id]

  multi_az                = true
  backup_retention_period = var.db_backup_retention_days
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  deletion_protection             = var.db_deletion_protection
  skip_final_snapshot             = !var.db_deletion_protection
  copy_tags_to_snapshot           = var.rds_copy_tags_to_snapshot
  performance_insights_enabled    = true
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  auto_minor_version_upgrade      = true

  tags = local.common_tags

  lifecycle {
    ignore_changes = [password, final_snapshot_identifier]
  }
}

resource "aws_db_instance" "replica" {
  count = var.db_read_replica_count

  identifier             = "${local.name_prefix}-db-replica-${count.index + 1}"
  replicate_source_db    = aws_db_instance.primary.identifier
  instance_class         = var.db_instance_class
  vpc_security_group_ids = [aws_security_group.db.id]
  storage_encrypted      = true
  kms_key_id             = var.enable_customer_managed_key ? aws_kms_key.main[0].arn : null

  performance_insights_enabled = true
  auto_minor_version_upgrade   = true
  skip_final_snapshot          = true

  tags = local.common_tags
}

# ----- ALB -----

resource "aws_s3_bucket" "alb_logs" {
  bucket_prefix = "${local.name_prefix}-alb-logs-"
  force_destroy = false
  tags          = local.common_tags
}

resource "aws_s3_bucket_versioning" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "expire"
    status = "Enabled"
    filter {}

    expiration {
      days = var.access_log_retention_days
    }
  }
}

data "aws_elb_service_account" "main" {}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = data.aws_elb_service_account.main.arn }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.alb_logs.arn}/*"
    }]
  })
}

resource "aws_lb" "main" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  drop_invalid_header_fields = true
  enable_http2               = true

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    enabled = true
  }

  tags = local.common_tags
}

resource "aws_lb_target_group" "main" {
  name        = "${local.name_prefix}-tg"
  port        = 443
  protocol    = "HTTPS"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    protocol            = "HTTPS"
    path                = "/health"
    port                = "443"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 15
  }

  deregistration_delay = 60
  tags                 = local.common_tags
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

# ----- Launch template + ASG -----

resource "aws_launch_template" "main" {
  name_prefix   = "${local.name_prefix}-lt-"
  image_id      = data.aws_ami.hailbytes.id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.vm.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.vm.name
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type           = "gp3"
      volume_size           = 50
      encrypted             = true
      kms_key_id            = var.enable_customer_managed_key ? aws_kms_key.main[0].arn : null
      delete_on_termination = true
    }
  }

  user_data = base64encode(jsonencode({
    hailbytes = {
      mode             = "scale-out"
      db_secret_arn    = aws_secretsmanager_secret.db.arn
      db_secret_region = data.aws_region.current.id
      product          = var.product
      redis_host       = local.effective_redis_host
      redis_port       = local.effective_redis_port
      redis_tls        = local.provision_managed_redis ? true : var.redis_endpoint_override_tls
    }
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = local.common_tags
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [image_id]
  }
}

resource "aws_autoscaling_group" "main" {
  name                = "${local.name_prefix}-asg"
  min_size            = var.asg_min_size
  max_size            = var.asg_max_size
  desired_capacity    = var.asg_desired_capacity
  vpc_zone_identifier = var.private_subnet_ids
  target_group_arns   = [aws_lb_target_group.main.arn]
  health_check_type   = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.main.id
    version = "$Latest"
  }

  # Rolling-refresh policy. min_healthy_percentage=50 lets one instance drain at a
  # time on a 2-instance ASG and keeps half capacity on larger ASGs; auto_rollback
  # triggers when CloudWatch alarms fire (see aws_cloudwatch_metric_alarm.refresh_*
  # below); skip_matching makes a re-apply with the same AMI a no-op.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = var.instance_refresh_min_healthy_percentage
      instance_warmup        = var.instance_refresh_instance_warmup_seconds
      auto_rollback          = true
      skip_matching          = true
      alarm_specification {
        alarms = [
          aws_cloudwatch_metric_alarm.refresh_5xx.alarm_name,
          aws_cloudwatch_metric_alarm.refresh_unhealthy.alarm_name,
        ]
      }
    }
    triggers = ["launch_template"]
  }

  dynamic "tag" {
    for_each = local.common_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_policy" "cpu" {
  name                   = "${local.name_prefix}-cpu-tt"
  autoscaling_group_name = aws_autoscaling_group.main.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.target_cpu_utilization
  }
}

resource "aws_autoscaling_policy" "req_per_target" {
  name                   = "${local.name_prefix}-req-tt"
  autoscaling_group_name = aws_autoscaling_group.main.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.main.arn_suffix}/${aws_lb_target_group.main.arn_suffix}"
    }
    target_value = var.target_request_count_per_target
  }
}

# ----- VPC Flow Logs -----

resource "aws_cloudwatch_log_group" "flow_logs" {
  count             = var.enable_flow_logs ? 1 : 0
  name              = "/aws/vpc-flow-logs/${local.name_prefix}"
  retention_in_days = 30
  kms_key_id        = var.enable_customer_managed_key ? aws_kms_key.main[0].arn : null
  tags              = local.common_tags
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0
  name  = "${local.name_prefix}-flow-logs"
  tags  = local.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0
  name  = "${local.name_prefix}-flow-logs"
  role  = aws_iam_role.flow_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_flow_log" "vpc" {
  count                = var.enable_flow_logs ? 1 : 0
  iam_role_arn         = aws_iam_role.flow_logs[0].arn
  log_destination      = aws_cloudwatch_log_group.flow_logs[0].arn
  log_destination_type = "cloud-watch-logs"
  traffic_type         = "ALL"
  vpc_id               = var.vpc_id
  tags                 = local.common_tags
}

# ----- SNS alerts -----

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

# ----- CloudWatch alarms -----

resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  alarm_name          = "${local.name_prefix}-unhealthy-targets"
  alarm_description   = "ALB target group has unhealthy targets"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.main.arn_suffix
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "db_cpu" {
  alarm_name          = "${local.name_prefix}-db-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.primary.id
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "db_storage" {
  alarm_name          = "${local.name_prefix}-db-storage-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 10 * 1024 * 1024 * 1024 # 10 GiB
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.primary.id
  }

  tags = local.common_tags
}

# ----- Rolling-refresh tripwire alarms -----
#
# These are referenced by the ASG instance_refresh alarm_specification. If either
# fires during a refresh, the ASG aborts the in-progress replacement and rolls
# back to the previous launch template. They live on the target group, not on
# the ASG, so the same alarms also serve as production health signals outside
# of refresh windows.

resource "aws_cloudwatch_metric_alarm" "refresh_5xx" {
  alarm_name          = "${local.name_prefix}-refresh-5xx-rate"
  alarm_description   = "Target group 5xx rate >1% over 2 minutes; rolls back in-progress ASG instance refresh."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = var.refresh_rollback_5xx_threshold_pct
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

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

resource "aws_cloudwatch_metric_alarm" "refresh_unhealthy" {
  alarm_name          = "${local.name_prefix}-refresh-unhealthy-targets"
  alarm_description   = "Target group has unhealthy hosts for 3 minutes after a refresh starts; rolls back."
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

# ----- Optional WAF attachment -----
#
# Procurement-grade option: customers bring their own Web ACL (commonly a
# centrally-managed corporate ruleset). We do not bundle a Web ACL — the spec
# in docs/PATCHING_AND_MIGRATION.md is explicit that WAF is supported, not
# enforced.

resource "aws_wafv2_web_acl_association" "alb" {
  count        = var.waf_web_acl_arn == null ? 0 : 1
  resource_arn = aws_lb.main.arn
  web_acl_arn  = var.waf_web_acl_arn
}

# ----- Backup bucket (pre-patch snapshots, /api/instance/export bundles) -----
#
# Bucket layout:
#   s3://<bucket>/hailbytes-sat-<timestamp>.tar.gz
# Lifecycle: STANDARD -> STANDARD_IA at 30d -> DEEP_ARCHIVE at 90d.
# Versioning + object-lock (governance, customer-controlled retention) protect
# against accidental overwrite and ransomware-grade tampering.
# IAM is scoped tightly: the SAT instance profile may PutObject under the
# hailbytes-sat-*.tar.gz prefix only.

locals {
  create_backup_bucket    = var.create_backup_bucket
  effective_backup_bucket = local.create_backup_bucket ? aws_s3_bucket.backup[0].id : var.backup_bucket_name
  backup_object_prefix    = "hailbytes-${var.product}-"
}

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
#
# Customer-initiated entry point that the AWS Console (Systems Manager ->
# Run Command -> select this document) wraps around the on-VM
# /opt/hailbytes/bin/ha-pre-patch-backup.sh script. The script reads the same
# Secrets Manager entries the instance already mounts (DB creds, encryption
# key), produces a bundle.json + db.sql + uploads/ tarball, and ships it to
# the backup bucket. It also takes a pre-refresh RDS snapshot so the runbook
# is one click.

resource "aws_ssm_document" "pre_patch_backup" {
  name            = "${local.name_prefix}-pre-patch-backup"
  document_type   = "Command"
  document_format = "YAML"
  target_type     = "/AWS::EC2::Instance"
  tags            = local.common_tags

  content = yamlencode({
    schemaVersion = "2.2"
    description   = "HailBytes SAT/ASM pre-patch backup. Bundles DB + uploads + manifest to the configured S3 bucket and triggers an RDS snapshot."
    parameters = {
      bucketName = {
        type        = "String"
        description = "S3 bucket name to receive the backup tarball. Defaults to the module-provisioned bucket."
        default     = local.effective_backup_bucket == null ? "" : local.effective_backup_bucket
      }
      rdsSnapshotIdentifier = {
        type        = "String"
        description = "Optional override for the RDS snapshot identifier. Defaults to a timestamped value."
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
            "if [ -x /opt/hailbytes/bin/ha-pre-patch-backup.sh ]; then sudo -E /opt/hailbytes/bin/ha-pre-patch-backup.sh; else echo 'ERROR: /opt/hailbytes/bin/ha-pre-patch-backup.sh not present on this AMI. Rebuild from main; the Packer provision.sh now installs the script.' >&2; exit 1; fi",
            "RDS_ID='{{ rdsSnapshotIdentifier }}'",
            "if [ -z \"$RDS_ID\" ]; then RDS_ID=\"${local.name_prefix}-pre-patch-$${TS}\"; fi",
            "aws rds create-db-snapshot --db-instance-identifier '${aws_db_instance.primary.id}' --db-snapshot-identifier \"$RDS_ID\" --tags Key=Module,Value=hailbytes-terraform-modules Key=Phase,Value=pre-patch",
          ]
        }
      }
    ]
  })
}

# ----- SSM Run Command document: post-patch verify -----

resource "aws_ssm_document" "post_patch_verify" {
  name            = "${local.name_prefix}-post-patch-verify"
  document_type   = "Command"
  document_format = "YAML"
  target_type     = "/AWS::EC2::Instance"
  tags            = local.common_tags

  content = yamlencode({
    schemaVersion = "2.2"
    description   = "HailBytes SAT/ASM post-patch verifier. Runs the five-probe on-VM verifier so the autoscaling instance_refresh can fail fast on a regression."
    parameters = {
      schemaVersionPath = {
        type        = "String"
        description = "Path to the schema-version endpoint."
        default     = var.schema_version_endpoint_path
      }
      minSchemaVersion = {
        type        = "String"
        description = "Optional integer floor that the running schema version must meet or exceed. Empty string skips the regression check."
        default     = ""
      }
    }
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "postPatchVerify"
        inputs = {
          timeoutSeconds = "600"
          runCommand = [
            "set -euo pipefail",
            "export HAILBYTES_SCHEMA_VERSION_PATH='{{ schemaVersionPath }}'",
            "export HAILBYTES_MIN_SCHEMA_VERSION='{{ minSchemaVersion }}'",
            "if [ -x /opt/hailbytes/bin/ha-post-patch-verify.sh ]; then sudo -E /opt/hailbytes/bin/ha-post-patch-verify.sh; else echo 'ERROR: /opt/hailbytes/bin/ha-post-patch-verify.sh not present on this AMI.'; exit 1; fi",
          ]
        }
      }
    ]
  })
}
