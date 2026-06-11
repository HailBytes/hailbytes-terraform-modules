# Minimal-input apply against a mocked AWS provider. Proves the module
# instantiates with only its required variable (name_prefix) and that every
# operator-facing output is populated.
#
# mock_data "aws_availability_zones" supplies three synthetic AZ names so the
# slice() call in main.tf locals resolves to a known list without real AWS
# credentials.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names    = ["us-east-1a", "us-east-1b", "us-east-1c"]
      zone_ids = ["use1-az1", "use1-az2", "use1-az3"]
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
    condition     = output.vpc_cidr != ""
    error_message = "vpc_cidr output must be non-empty"
  }

  assert {
    condition     = length(output.public_subnet_ids) == 2
    error_message = "public_subnet_ids must contain one entry per AZ (default az_count=2)"
  }

  assert {
    condition     = length(output.private_subnet_ids) == 2
    error_message = "private_subnet_ids must contain one entry per AZ (default az_count=2)"
  }

  assert {
    condition     = length(output.db_subnet_ids) == 2
    error_message = "db_subnet_ids must contain one entry per AZ (default az_count=2)"
  }

  assert {
    condition     = output.internet_gateway_id != ""
    error_message = "internet_gateway_id output must be non-empty"
  }

  assert {
    condition     = length(output.nat_gateway_ids) == 2
    error_message = "nat_gateway_ids must contain one entry per AZ when enable_nat_gateway=true (the default)"
  }
}
