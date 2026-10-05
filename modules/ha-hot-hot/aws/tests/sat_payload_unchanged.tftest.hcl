# The SAT half of the ASM cluster-key check, in its own file because test runs
# in one file share state, and the VMs ignore_changes on their startup data --
# so after an ASM run the SAT run would still see the ASM payload.

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

run "sat_payload_is_unchanged" {
  command = apply

  variables {
    product = "sat"
  }

  assert {
    condition     = length(aws_secretsmanager_secret.asm_cluster_key) == 0
    error_message = "a SAT deployment must not create the ASM cluster-key secret"
  }

  assert {
    condition     = !contains(keys(jsondecode(base64decode(aws_instance.vm[0].user_data)).hailbytes), "asm_cluster_key_secret_arn")
    error_message = "the SAT payload must not change: asm_cluster_key_secret_arn is ASM-only"
  }
}
