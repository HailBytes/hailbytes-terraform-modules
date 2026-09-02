# Conditional resources must respect their feature flags, and the autoscale
# tier must run a Multi-AZ primary plus read replicas. Plan-only checks.

mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock-role" }
  }
  # Needed only by the apply-command run at the end of this file; harmless for
  # the plan-only runs above.
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/mock/0000000000000000" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/mock/0000000000000000" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:123456789012:mock-topic" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:mock:*" }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-00000000000000000" }
  }
}

mock_provider "random" {}

variables {
  product             = "asm"
  vpc_id              = "vpc-00000000000000001"
  public_subnet_ids   = ["subnet-00000000000000001", "subnet-00000000000000002"]
  private_subnet_ids  = ["subnet-00000000000000003", "subnet-00000000000000004", "subnet-00000000000000005"]
  allowed_cidrs       = ["10.0.0.0/8"]
  acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"

  create_backup_bucket = false
  backup_bucket_name   = null
}

run "rds_is_multi_az_with_replicas" {
  command = plan

  assert {
    condition     = aws_db_instance.primary.multi_az == true
    error_message = "Autoscale tier primary RDS instance must be Multi-AZ."
  }

  assert {
    condition     = length(aws_db_instance.replica) == 2
    error_message = "Default db_read_replica_count of 2 must create two read replicas."
  }
}

run "kms_enabled_by_default" {
  command = plan

  assert {
    condition     = length(aws_kms_key.main) == 1
    error_message = "Autoscale tier defaults enable_customer_managed_key = true and must create one KMS key."
  }
}

run "kms_disabled_creates_no_key" {
  command = plan

  variables {
    enable_customer_managed_key = false
  }

  assert {
    condition     = length(aws_kms_key.main) == 0
    error_message = "enable_customer_managed_key = false must create zero KMS keys."
  }
}

run "managed_redis_by_default" {
  command = plan

  assert {
    condition     = length(aws_elasticache_replication_group.main) == 1
    error_message = "Managed Redis is the autoscale default and must create one ElastiCache replication group."
  }

  assert {
    condition     = output.redis_mode == "managed"
    error_message = "redis_mode must be 'managed' by default."
  }
}

run "redis_disabled_creates_nothing" {
  command = plan

  variables {
    enable_managed_redis = false
  }

  assert {
    condition     = length(aws_elasticache_replication_group.main) == 0
    error_message = "enable_managed_redis = false with no override must create zero ElastiCache replication groups."
  }

  assert {
    condition     = output.redis_mode == "disabled"
    error_message = "redis_mode must be 'disabled' when managed Redis is off and no override is supplied."
  }
}

# Same IMDSv2 requirement as the other tiers, but on the launch template — the
# ASG path is easy to miss because the setting lives one level deeper.
# https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-options.html
run "imdsv2_is_required_on_the_launch_template" {
  command = plan

  assert {
    condition     = one([for m in aws_launch_template.main.metadata_options : m.http_tokens]) == "required"
    error_message = "IMDSv2 must be required on the launch template, or every scaled-out instance exposes IMDSv1."
  }
}

# ----- SAT phishing/landing frontend -----
#
# The tier shipped with local.phish_port computed and never referenced: SAT
# autoscale deployments served no landing pages, which is the product. These
# runs pin the wiring, the ASM no-op, and the split allow-list.

run "phish_frontend_absent_on_asm" {
  command = plan

  # ASM has no phishing surface. Setting the allow-list must still open nothing:
  # the wrappers forward every core variable, so an ASM caller can pass it.
  variables {
    phish_allowed_cidrs = ["0.0.0.0/0"]
  }

  assert {
    condition     = length(aws_lb_target_group.phish) == 0
    error_message = "ASM has no phishing surface and must create no phishing target group."
  }

  assert {
    condition     = length(aws_lb_listener.phish) == 0
    error_message = "ASM has no phishing surface and must create no phishing listener."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.alb_phish) == 0
    error_message = "Setting phish_allowed_cidrs on ASM must open nothing on the ALB."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.alb_to_vm_phish) == 0
    error_message = "ASM must get no ALB egress rule for a phishing port it does not bind."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.vm_from_alb_phish) == 0
    error_message = "ASM must get no instance ingress rule for a phishing port it does not bind."
  }

  assert {
    condition     = length(aws_lb_listener.http_redirect) == 1
    error_message = "ASM keeps its :80 HTTP->HTTPS redirect; this change must be a no-op for it."
  }

  assert {
    condition     = length(aws_autoscaling_group.main.target_group_arns) == 1
    error_message = "ASM instances must register in the admin target group only."
  }
}

run "phish_frontend_wired_on_sat" {
  command = plan

  variables {
    product = "sat"
  }

  assert {
    condition     = length(aws_lb_target_group.phish) == 1
    error_message = "SAT must get a phishing target group -- landing pages and interaction tracking are the product."
  }

  assert {
    condition     = aws_lb_target_group.phish[0].port == 80 && aws_lb_target_group.phish[0].protocol == "HTTP"
    error_message = "The phishing target group must forward plaintext HTTP to phish_port (80); the phish server binds :80 with use_tls false."
  }

  # The load-bearing assertion. ha-hot-hot/azure probes phish_port over Tcp
  # because no path on the phish server is guaranteed to answer 200 on a fresh
  # deployment; an ALB cannot do TCP checks, so the equivalent is a permissive
  # matcher. "/" falls through to PhishHandler, which answers 404 with no
  # campaign RID -- narrowing this to "200" drains every target, and with
  # health_check_type = "ELB" the ASG then terminates the whole fleet.
  assert {
    condition     = one([for h in aws_lb_target_group.phish[0].health_check : h.matcher]) == "200-499"
    error_message = "The phishing health check must accept 200-499: a fresh phish server answers 404 on \"/\", and a configured landing page answers 302."
  }

  assert {
    condition     = one([for h in aws_lb_target_group.phish[0].health_check : h.protocol]) == "HTTP"
    error_message = "The phishing health check must probe over HTTP, not HTTPS -- nothing terminates TLS on phish_port."
  }

  assert {
    condition     = length(aws_lb_listener.phish) == 1 && aws_lb_listener.phish[0].port == 80
    error_message = "SAT must front the phishing surface on the ALB's port 80."
  }

  assert {
    condition     = one([for a in aws_lb_listener.phish[0].default_action : a.type]) == "forward"
    error_message = "SAT's :80 listener must forward to the phishing target group, not redirect."
  }

  # Decision: :80 cannot both redirect and serve landing pages, so
  # enable_http_redirect (default true) is ASM-only rather than a plan error.
  assert {
    condition     = length(aws_lb_listener.http_redirect) == 0
    error_message = "enable_http_redirect must be inert on SAT: a 301 sent to a target who clicked a phishing link breaks the simulation."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.alb_http_redirect) == 0
    error_message = "The redirect's :80 ingress rule must not coexist with the phishing ingress rule on SAT."
  }
}

# The admin allow-list and the phishing allow-list have opposite audiences: the
# console is for operators on an office or VPN range, the landing pages are for
# targets who are by definition somewhere else. Mirrors the ha-hot-hot/azure
# coverage added when that bug class was first fixed.
run "phish_allow_list_inherits_admin_list_by_default" {
  command = plan

  variables {
    product = "sat"
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.alb_phish) == 1
    error_message = "With phish_allowed_cidrs unset, the phishing rules must mirror allowed_cidrs one-for-one -- an existing deployment has to plan clean."
  }

  assert {
    condition = alltrue([
      for k, r in aws_vpc_security_group_ingress_rule.alb_phish : contains(var.allowed_cidrs, r.cidr_ipv4)
    ])
    error_message = "The inherited phishing rules must carry the same source CIDRs as the admin rules."
  }
}

run "phish_allow_list_is_independent_when_set" {
  command = plan

  variables {
    product             = "sat"
    phish_allowed_cidrs = ["0.0.0.0/0"]
  }

  assert {
    condition = alltrue([
      for k, r in aws_vpc_security_group_ingress_rule.alb_phish : r.cidr_ipv4 == "0.0.0.0/0"
    ])
    error_message = "phish_allowed_cidrs must govern the phishing frontend on its own."
  }

  assert {
    condition = alltrue([
      for k, r in aws_vpc_security_group_ingress_rule.alb_https : r.cidr_ipv4 == "10.0.0.0/8"
    ])
    error_message = "Opening the phishing surface must NOT widen the admin surface -- that is the whole point of splitting the lists."
  }
}

# A wired listener that the ASG never registers instances into is still an empty
# pool and a 503, which is the failure ad451cf fixed on the admin side. The ARNs
# are only known after apply, so this is the one run here that applies.
run "sat_instances_register_in_both_target_groups" {
  command = apply

  variables {
    product            = "sat"
    backup_bucket_name = "hailbytes-test-backups"
  }

  # target_group_arns is a set, so the two groups need distinct ARNs or they
  # collapse into one element and the count assertion below passes vacuously.
  override_resource {
    target = aws_lb_target_group.main
    values = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/mock-admin/0000000000000001"
    }
  }

  override_resource {
    target = aws_lb_target_group.phish[0]
    values = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/mock-phish/0000000000000002"
    }
  }

  assert {
    condition     = length(aws_autoscaling_group.main.target_group_arns) == 2
    error_message = "SAT instances must register in both the admin and the phishing target group, or the phishing pool stays empty and :80 serves 503."
  }

  assert {
    condition     = contains(aws_autoscaling_group.main.target_group_arns, aws_lb_target_group.phish[0].arn)
    error_message = "The ASG must register instances in the phishing target group specifically."
  }
}
