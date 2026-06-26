# Conditional resources must respect their feature flags. All runs use
# command = plan; no apply or credentials are needed.
#
# Every run explicitly sets enable_nat_gateway = false. When nat is enabled the
# private route table's for_each references aws_nat_gateway.main[*].id, which
# is unknown at plan time. Setting it false makes the for_each evaluate to []
# (always known) so each run can focus on the flag under test in isolation.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
      ids   = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }
}

variables {
  name_prefix        = "hailbytes-test"
  enable_nat_gateway = false
}

run "nat_disabled_creates_no_gateways" {
  command = plan

  assert {
    condition     = length(aws_nat_gateway.main) == 0
    error_message = "enable_nat_gateway = false must create zero NAT gateways."
  }

  assert {
    condition     = length(aws_eip.nat) == 0
    error_message = "enable_nat_gateway = false must create zero Elastic IPs."
  }
}

run "flow_logs_disabled_creates_no_resources" {
  command = plan

  variables {
    enable_flow_logs = false
  }

  assert {
    condition     = length(aws_flow_log.main) == 0
    error_message = "enable_flow_logs = false must create zero VPC Flow Log resources."
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.flow_logs) == 0
    error_message = "enable_flow_logs = false must create zero CloudWatch log groups."
  }

  assert {
    condition     = length(aws_iam_role.flow_logs) == 0
    error_message = "enable_flow_logs = false must create zero IAM roles for flow logs."
  }
}

run "flow_logs_enabled_creates_one_set" {
  command = plan

  assert {
    condition     = length(aws_flow_log.main) == 1
    error_message = "enable_flow_logs = true (the default) must create exactly one flow log."
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.flow_logs) == 1
    error_message = "enable_flow_logs = true must create exactly one CloudWatch log group."
  }
}

run "three_az_span_creates_three_subnets_each" {
  command = plan

  variables {
    az_count = 3
  }

  assert {
    condition     = length(aws_subnet.public) == 3
    error_message = "az_count = 3 must create three public subnets."
  }

  assert {
    condition     = length(aws_subnet.private) == 3
    error_message = "az_count = 3 must create three private subnets."
  }

  assert {
    condition     = length(aws_subnet.db) == 3
    error_message = "az_count = 3 must create three database subnets."
  }
}
