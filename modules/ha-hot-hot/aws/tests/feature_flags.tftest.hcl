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
