# Conditional resources must respect their feature flags. These are plan-only
# checks on resource counts, so no apply or credentials are needed.

mock_provider "aws" {}

variables {
  product       = "asm"
  vpc_id        = "vpc-00000000000000001"
  subnet_id     = "subnet-00000000000000001"
  allowed_cidrs = ["10.0.0.0/8"]
  # Keep the backup bucket out of the picture so effective_backup_bucket stays a
  # known value (see basic.tftest.hcl for why the create=true branch is not
  # mock-testable).
  create_backup_bucket = false
  backup_bucket_name   = null
}

run "kms_disabled_by_default" {
  command = plan

  assert {
    condition     = length(aws_kms_key.ebs) == 0
    error_message = "No customer-managed KMS key may be created when enable_customer_managed_key is false (the default)."
  }
}

run "kms_enabled_creates_one_key" {
  command = plan

  variables {
    enable_customer_managed_key = true
  }

  assert {
    condition     = length(aws_kms_key.ebs) == 1
    error_message = "enable_customer_managed_key = true must create exactly one KMS key."
  }
}

run "backup_bucket_not_created_when_disabled" {
  command = plan

  assert {
    condition     = length(aws_s3_bucket.backup) == 0
    error_message = "create_backup_bucket = false must create zero S3 backup buckets."
  }

  assert {
    condition     = length(aws_iam_role_policy.backup_put) == 0
    error_message = "With no backup bucket configured, the backup PutObject policy must not be attached."
  }
}

run "snapshots_disabled_creates_no_dlm" {
  command = plan

  variables {
    enable_snapshots = false
  }

  assert {
    condition     = length(aws_dlm_lifecycle_policy.snapshots) == 0
    error_message = "enable_snapshots = false must create zero DLM lifecycle policies."
  }
}
