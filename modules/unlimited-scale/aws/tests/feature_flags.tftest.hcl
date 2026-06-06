# Conditional resources must respect their feature flags, and the autoscale
# tier must run a Multi-AZ primary plus read replicas. Plan-only checks.

mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock-role" }
  }
}

mock_provider "random" {}

variables {
  product             = "asm"
  vpc_id              = "vpc-00000000000000001"
  public_subnet_ids   = ["subnet-00000000000000001", "subnet-00000000000000002"]
  private_subnet_ids  = ["subnet-00000000000000003", "subnet-00000000000000004", "subnet-00000000000000005"]
  allowed_cidrs       = ["10.0.0.0/8"]
  acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"

  create_backup_bucket = false
  backup_bucket_name   = null
}

run "rds_is_multi_az_with_replicas" {
  command = plan

  assert {
    condition     = aws_db_instance.primary.multi_az == true
    error_message = "Autoscale tier primary RDS instance must be Multi-AZ."
  }

  assert {
    condition     = length(aws_db_instance.replica) == 2
    error_message = "Default db_read_replica_count of 2 must create two read replicas."
  }
}

run "kms_enabled_by_default" {
  command = plan

  assert {
    condition     = length(aws_kms_key.main) == 1
    error_message = "Autoscale tier defaults enable_customer_managed_key = true and must create one KMS key."
  }
}

run "kms_disabled_creates_no_key" {
  command = plan

  variables {
    enable_customer_managed_key = false
  }

  assert {
    condition     = length(aws_kms_key.main) == 0
    error_message = "enable_customer_managed_key = false must create zero KMS keys."
  }
}

run "managed_redis_by_default" {
  command = plan

  assert {
    condition     = length(aws_elasticache_replication_group.main) == 1
    error_message = "Managed Redis is the autoscale default and must create one ElastiCache replication group."
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
