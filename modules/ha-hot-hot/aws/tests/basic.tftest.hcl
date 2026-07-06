# Minimal-input apply against a mocked AWS provider. Proves the HA tier
# instantiates with only its required variables and that the load-balancer,
# instance, database and Redis outputs are all populated.
#
# As in single-vm/aws, the backup bucket is supplied by name and
# create_backup_bucket is left false: the create=true branch derives a `count`
# from the bucket id, which the mock provider cannot make known at plan time.

mock_provider "aws" {
  # Several resources validate that referenced values are well-formed ARNs. The
  # mock provider fills computed strings with short random tokens, so give the
  # types whose ARNs flow into validated arguments a valid-looking ARN.
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock-role" }
  }
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/mock/0000000000000000" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/mock/0000000000000000" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:123456789012:mock-topic" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/vpc-flow-logs/mock:*"
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
  backup_bucket_name   = "hailbytes-test-backups"
}

run "minimal_inputs_apply" {
  command = apply

  assert {
    condition     = output.alb_dns_name != ""
    error_message = "alb_dns_name output must be non-empty"
  }

  assert {
    condition     = length(output.instance_ids) == 2
    error_message = "HA tier must stand up exactly two active/active VMs"
  }

  assert {
    condition     = output.db_endpoint != ""
    error_message = "db_endpoint output must be non-empty"
  }

  assert {
    condition     = output.db_secret_arn != ""
    error_message = "db_secret_arn output must be non-empty"
  }

  assert {
    condition     = output.ami_id != ""
    error_message = "ami_id output must be non-empty (marketplace AMI lookup must resolve)"
  }

  assert {
    condition     = output.redis_endpoint != ""
    error_message = "redis_endpoint output must be non-empty when managed Redis is enabled (the default)"
  }

  assert {
    condition     = output.flow_log_group_name != ""
    error_message = "flow_log_group_name output must be non-empty when enable_flow_logs is true (the default)"
  }
}
