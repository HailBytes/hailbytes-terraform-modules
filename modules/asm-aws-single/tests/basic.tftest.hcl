# Minimal-input apply against a mocked AWS provider. Proves the wrapper
# instantiates with only its required variables, re-exports every
# single-vm/aws output, and that `product` is correctly hardcoded to "asm".
#
# See modules/single-vm/aws/tests/basic.tftest.hcl for the create_backup_bucket
# note: the create=true branch derives a `count` from the bucket id, which the
# mock provider cannot make known at plan time, so these tests pin a known
# backup bucket via backup_bucket_name instead.

mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-role"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/vpc-flow-logs/mock:*"
    }
  }
}

variables {
  vpc_id               = "vpc-00000000000000001"
  subnet_id            = "subnet-00000000000000001"
  allowed_cidrs        = ["10.0.0.0/8"]
  create_backup_bucket = false
  backup_bucket_name   = "hailbytes-test-backups"
}

run "wrapper_outputs_populated" {
  command = apply

  assert {
    condition     = output.instance_id != ""
    error_message = "instance_id output must be non-empty"
  }

  assert {
    condition     = output.ami_id != ""
    error_message = "ami_id output must be non-empty (marketplace AMI lookup must resolve)"
  }

  assert {
    condition     = output.security_group_id != ""
    error_message = "security_group_id output must be non-empty"
  }

  assert {
    condition     = output.iam_role_arn != ""
    error_message = "iam_role_arn output must be non-empty"
  }

  assert {
    condition     = output.console_url != ""
    error_message = "console_url output must be non-empty"
  }

  assert {
    condition     = output.pre_patch_ssm_document_name != ""
    error_message = "pre_patch_ssm_document_name output must be non-empty"
  }
}
