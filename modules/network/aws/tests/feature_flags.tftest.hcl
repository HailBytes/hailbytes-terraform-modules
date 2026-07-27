# Conditional resources must respect their feature flags. All runs use
# command = plan; no apply or credentials are needed.
#
# The file-level default is enable_nat_gateway = false so each run can focus on
# the flag under test in isolation: with nat disabled the private route table's
# dynamic route for_each evaluates to [] (always known) instead of carrying an
# unknown gateway id. The one run that needs real gateways —
# one_nat_gateway_per_availability_zone — overrides it locally.

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

# A NAT gateway is zonal: it lives in one AZ and traffic from other AZs crosses
# a zone boundary to reach it, so a single gateway is a single-AZ dependency for
# every private subnet. AWS's guidance is one per AZ, which is what az_count
# drives here.
# https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html
run "one_nat_gateway_per_availability_zone" {
  command = plan

  # Overrides the file-level enable_nat_gateway = false; this is the one run
  # that needs the gateways to actually exist.
  variables {
    enable_nat_gateway = true
    az_count           = 3
  }

  assert {
    condition     = length(aws_nat_gateway.main) == 3
    error_message = "There must be one NAT gateway per AZ; a shared one makes every private subnet depend on a single zone."
  }

  assert {
    condition     = length(aws_eip.nat) == 3
    error_message = "Each NAT gateway needs its own Elastic IP."
  }

  # Each gateway must sit in the public subnet of its own AZ — a NAT gateway in a
  # private subnet has no route to the internet gateway. Subnet IDs are computed
  # and so unknown at plan, but the *count* pairing is knowable: three gateways,
  # three public subnets, three private route tables, one per AZ.
  assert {
    condition     = length(aws_subnet.public) == 3 && length(aws_route_table.private) == 3
    error_message = "Each AZ needs its own public subnet to host a gateway and its own private route table to point at it; a shared route table collapses egress onto one zone."
  }

  # Every EIP must be in the VPC domain. A classic-domain EIP cannot be attached
  # to a NAT gateway at all.
  assert {
    condition     = alltrue([for e in aws_eip.nat : e.domain == "vpc"])
    error_message = "NAT gateway Elastic IPs must be VPC-domain."
  }
}
