# Conditional resources must respect their feature flags. Plan-only checks on
# resource counts — no apply or real credentials needed.

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

run "nat_gateway_disabled_creates_none" {
  command = plan

  variables {
    enable_nat_gateway = false
  }

  assert {
    condition     = length(aws_nat_gateway.main) == 0
    error_message = "enable_nat_gateway=false must create zero NAT gateways."
  }

  assert {
    condition     = length(aws_eip.nat) == 0
    error_message = "enable_nat_gateway=false must allocate zero Elastic IPs."
  }
}

run "nat_gateway_enabled_creates_one_per_az" {
  command = plan

  assert {
    condition     = length(aws_nat_gateway.main) == 2
    error_message = "enable_nat_gateway=true with az_count=2 must create exactly two NAT gateways."
  }
}

run "flow_logs_disabled_creates_no_resources" {
  command = plan

  variables {
    enable_flow_logs = false
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.flow_logs) == 0
    error_message = "enable_flow_logs=false must create zero CloudWatch log groups."
  }

  assert {
    condition     = length(aws_iam_role.flow_logs) == 0
    error_message = "enable_flow_logs=false must create zero IAM roles for flow logs."
  }

  assert {
    condition     = length(aws_flow_log.main) == 0
    error_message = "enable_flow_logs=false must create zero VPC flow log resources."
  }
}

run "az_count_three_creates_three_subnets_per_tier" {
  command = plan

  variables {
    az_count = 3
  }

  assert {
    condition     = length(aws_subnet.public) == 3
    error_message = "az_count=3 must create three public subnets."
  }

  assert {
    condition     = length(aws_subnet.private) == 3
    error_message = "az_count=3 must create three private subnets."
  }

  assert {
    condition     = length(aws_subnet.db) == 3
    error_message = "az_count=3 must create three DB subnets."
  }

  assert {
    condition     = length(aws_nat_gateway.main) == 3
    error_message = "az_count=3 with enable_nat_gateway=true must create three NAT gateways."
  }
}
