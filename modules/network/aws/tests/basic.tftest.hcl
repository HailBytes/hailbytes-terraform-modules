# Minimal-input apply against a mocked AWS provider. No real credentials and no
# API calls — the mock provider stubs the provider entirely. This proves the
# module instantiates with only its required variables and that every
# operator-facing output is populated.
#
# The aws_availability_zones data source is overridden via mock_data so that
# slice(names, 0, az_count) evaluates to a known, non-empty list. Without this
# override the mock provider returns an empty list and the slice call fails.
#
# The apply command is used (rather than plan) because the private route tables
# reference aws_nat_gateway.main[*].id inside a for_each. With mock apply the
# provider generates deterministic mock IDs for all resources, so that reference
# is fully known; with plan only, it would be unknown and Terraform would refuse
# to evaluate the for_each.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
      ids   = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  # Flow-log IAM role ARN must look like a real ARN so downstream policy
  # resources that reference it pass provider-side validation.
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-role"
    }
  }
}

variables {
  name_prefix = "hailbytes-test"
}

run "minimal_inputs_apply" {
  command = apply

  assert {
    condition     = output.vpc_id != ""
    error_message = "vpc_id output must be non-empty"
  }

  assert {
    condition     = output.vpc_cidr == "10.0.0.0/16"
    error_message = "vpc_cidr must match the default value"
  }

  assert {
    condition     = length(output.public_subnet_ids) == 2
    error_message = "public_subnet_ids must contain one entry per AZ (default az_count = 2)"
  }

  assert {
    condition     = length(output.private_subnet_ids) == 2
    error_message = "private_subnet_ids must contain one entry per AZ (default az_count = 2)"
  }

  assert {
    condition     = length(output.db_subnet_ids) == 2
    error_message = "db_subnet_ids must contain one entry per AZ (default az_count = 2)"
  }

  assert {
    condition     = output.internet_gateway_id != ""
    error_message = "internet_gateway_id output must be non-empty"
  }

  assert {
    condition     = length(output.nat_gateway_ids) == 2
    error_message = "nat_gateway_ids must contain 2 entries when enable_nat_gateway = true (the default)"
  }

  assert {
    condition     = length(output.nat_gateway_public_ips) == 2
    error_message = "nat_gateway_public_ips must contain 2 entries when enable_nat_gateway = true (the default)"
  }
}
