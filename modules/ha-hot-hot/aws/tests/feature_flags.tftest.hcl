# Conditional resources must respect their feature flags, and HA must run a
# Multi-AZ database. Plan-only count/attribute checks; no credentials needed.

mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-role"
    }
  }
}

mock_provider "random" {}

variables {
  product             = "asm"
  vpc_id              = "vpc-00000000000000001"
  public_subnet_ids   = ["subnet-00000000000000001", "subnet-00000000000000002"]
  private_subnet_ids  = ["subnet-00000000000000003", "subnet-00000000000000004"]
  allowed_cidrs       = ["10.0.0.0/8"]
  acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"

  create_backup_bucket = false
  backup_bucket_name   = null
}

run "rds_is_multi_az" {
  command = plan

  assert {
    condition     = aws_db_instance.main[0].multi_az == true
    error_message = "HA tier RDS instance must be Multi-AZ."
  }

  assert {
    condition     = output.db_mode == "rds"
    error_message = "Default db_mode must be 'rds'."
  }
}

run "kms_disabled_by_default" {
  command = plan

  assert {
    condition     = length(aws_kms_key.main) == 0
    error_message = "No customer-managed KMS key may be created when enable_customer_managed_key is false (the default)."
  }
}

run "kms_enabled_creates_one_key" {
  command = plan

  variables {
    enable_customer_managed_key = true
  }

  assert {
    condition     = length(aws_kms_key.main) == 1
    error_message = "enable_customer_managed_key = true must create exactly one KMS key."
  }
}

run "managed_redis_by_default" {
  command = plan

  assert {
    condition     = length(aws_elasticache_replication_group.main) == 1
    error_message = "Managed Redis is the HA default and must create one ElastiCache replication group."
  }

  assert {
    condition     = output.redis_mode == "managed"
    error_message = "redis_mode must be 'managed' by default."
  }
}

run "redis_disabled_creates_nothing" {
  command = plan

  variables {
    enable_managed_redis = false
  }

  assert {
    condition     = length(aws_elasticache_replication_group.main) == 0
    error_message = "enable_managed_redis = false with no override must create zero ElastiCache replication groups."
  }

  assert {
    condition     = output.redis_mode == "disabled"
    error_message = "redis_mode must be 'disabled' when managed Redis is off and no override is supplied."
  }
}

run "flow_logs_enabled_by_default" {
  command = plan

  assert {
    condition     = length(aws_flow_log.vpc) == 1
    error_message = "enable_flow_logs defaults to true and must create exactly one VPC flow log."
  }
}

run "flow_logs_disabled_creates_nothing" {
  command = plan

  variables {
    enable_flow_logs = false
  }

  assert {
    condition     = length(aws_flow_log.vpc) == 0
    error_message = "enable_flow_logs = false must create zero VPC flow logs."
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.flow_logs) == 0
    error_message = "enable_flow_logs = false must create zero flow-log CloudWatch log groups."
  }

  assert {
    condition     = output.flow_log_group_name == ""
    error_message = "flow_log_group_name must be empty string when enable_flow_logs is false."
  }
}

# db_mode = "external": the customer already runs Postgres, so we provision
# none. Same escape hatch as redis_endpoint_override.
run "external_db_provisions_no_database" {
  command = plan

  variables {
    db_mode              = "external"
    external_db_host     = "pg.internal.example.org"
    external_db_password = "not-a-real-password"
  }

  assert {
    condition     = length(aws_db_instance.main) == 0
    error_message = "db_mode = external must create zero RDS instances."
  }

  assert {
    condition     = length(aws_instance.db_ec2) == 0
    error_message = "db_mode = external must create zero database EC2 instances."
  }

  assert {
    condition     = output.db_is_customer_managed == true
    error_message = "db_is_customer_managed must be true in external mode."
  }

  assert {
    condition     = length(aws_instance.vm) == 2
    error_message = "external mode changes only the database; the two app instances remain."
  }
}

run "external_db_requires_host_and_password" {
  command = plan

  variables {
    db_mode = "external"
  }

  expect_failures = [random_password.db]
}

# TLS to RDS is enforced with the rds.force_ssl parameter, not with a client-side
# connection string: with force_ssl = 0 a misconfigured client silently
# downgrades to plaintext inside the VPC.
# https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Concepts.General.SSL.html
run "database_tls_is_enforced_server_side" {
  command = plan

  assert {
    condition = one([
      for p in aws_db_parameter_group.main[0].parameter : p.value if p.name == "rds.force_ssl"
    ]) == "1"
    error_message = "rds.force_ssl must be 1; without it a client can silently connect in plaintext."
  }
}
