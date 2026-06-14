# Minimal-input apply against a mocked AWS provider. No real credentials and no
# API calls — the mock provider stubs the provider entirely. This proves the
# module instantiates with only its required variables and that every
# operator-facing output is populated.
#
# NOTE on create_backup_bucket: the module derives several `count` arguments
# from the backup bucket's id (e.g. aws_iam_role_policy.backup_put). With the
# real AWS provider that id is known at plan time, but the mock provider marks
# all computed attributes as unknown, and Terraform refuses to evaluate
# count/for_each from unknown (or mock-overridden) values. So these tests pin a
# known backup bucket via backup_bucket_name and exercise the
# create_backup_bucket = false branch; the true branch can only be covered by a
# real-provider plan, which is out of scope for the credential-free CI gate.

mock_provider "aws" {
  # The mock provider fills computed strings with short random tokens. Some
  # resources validate that referenced values are well-formed ARNs (e.g. the
  # DLM lifecycle policy's execution_role_arn), so give IAM roles a valid ARN.
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-role"
    }
  }
}

variables {
  product              = "asm"
  vpc_id               = "vpc-00000000000000001"
  subnet_id            = "subnet-00000000000000001"
  allowed_cidrs        = ["10.0.0.0/8"]
  create_backup_bucket = false
  backup_bucket_name   = "hailbytes-test-backups"
}

run "minimal_inputs_apply" {
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
