# Conditional resources must respect their feature flags, and HA must run a
# Multi-AZ database. Plan-only count/attribute checks; no credentials needed.

mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-role"
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
  backup_bucket_name   = null
}

run "rds_is_multi_az" {
  command = plan

  assert {
    condition     = aws_db_instance.main[0].multi_az == true
    error_message = "HA tier RDS instance must be Multi-AZ."
  }

  assert {
    condition     = output.db_mode == "rds"
    error_message = "Default db_mode must be 'rds'."
  }
}

run "kms_disabled_by_default" {
  command = plan

  assert {
    condition     = length(aws_kms_key.main) == 0
    error_message = "No customer-managed KMS key may be created when enable_customer_managed_key is false (the default)."
  }
}

run "kms_enabled_creates_one_key" {
  command = plan

  variables {
    enable_customer_managed_key = true
  }

  assert {
    condition     = length(aws_kms_key.main) == 1
    error_message = "enable_customer_managed_key = true must create exactly one KMS key."
  }
}

run "managed_redis_by_default" {
  command = plan

  assert {
    condition     = length(aws_elasticache_replication_group.main) == 1
    error_message = "Managed Redis is the HA default and must create one ElastiCache replication group."
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

run "flow_logs_enabled_by_default" {
  command = plan

  assert {
    condition     = length(aws_flow_log.vpc) == 1
    error_message = "enable_flow_logs defaults to true and must create exactly one VPC flow log."
  }
}

run "flow_logs_disabled_creates_nothing" {
  command = plan

  variables {
    enable_flow_logs = false
  }

  assert {
    condition     = length(aws_flow_log.vpc) == 0
    error_message = "enable_flow_logs = false must create zero VPC flow logs."
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.flow_logs) == 0
    error_message = "enable_flow_logs = false must create zero flow-log CloudWatch log groups."
  }

  assert {
    condition     = output.flow_log_group_name == ""
    error_message = "flow_log_group_name must be empty string when enable_flow_logs is false."
  }
}

# db_mode = "external": the customer already runs Postgres, so we provision
# none. Same escape hatch as redis_endpoint_override.
run "external_db_provisions_no_database" {
  command = plan

  variables {
    db_mode              = "external"
    external_db_host     = "pg.internal.example.org"
    external_db_password = "not-a-real-password"
  }

  assert {
    condition     = length(aws_db_instance.main) == 0
    error_message = "db_mode = external must create zero RDS instances."
  }

  assert {
    condition     = length(aws_instance.db_ec2) == 0
    error_message = "db_mode = external must create zero database EC2 instances."
  }

  assert {
    condition     = output.db_is_customer_managed == true
    error_message = "db_is_customer_managed must be true in external mode."
  }

  assert {
    condition     = length(aws_instance.vm) == 2
    error_message = "external mode changes only the database; the two app instances remain."
  }
}

run "external_db_requires_host_and_password" {
  command = plan

  variables {
    db_mode = "external"
  }

  expect_failures = [random_password.db]
}

# TLS to RDS is enforced with the rds.force_ssl parameter, not with a client-side
# connection string: with force_ssl = 0 a misconfigured client silently
# downgrades to plaintext inside the VPC.
# https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Concepts.General.SSL.html
run "database_tls_is_enforced_server_side" {
  command = plan

  assert {
    condition = one([
      for p in aws_db_parameter_group.main[0].parameter : p.value if p.name == "rds.force_ssl"
    ]) == "1"
    error_message = "rds.force_ssl must be 1; without it a client can silently connect in plaintext."
  }
}

# ----- SAT phishing/landing frontend -----
#
# This tier had no phishing surface at all -- no target group, no port-80
# forwarding rule, no security-group rule, and no phish_port variable to set --
# so SAT on the AWS HA tier served no landing pages, which is the product.
# These runs pin the wiring, the ASM no-op, and the split allow-list.

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
    condition     = length(aws_lb_target_group_attachment.vm_phish) == 0
    error_message = "ASM VMs must not be attached to a phishing target group."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.alb_phish) == 0
    error_message = "Setting phish_allowed_cidrs on ASM must open nothing on the ALB."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.alb_out_phish) == 0
    error_message = "ASM must get no ALB egress rule for a phishing port it does not bind."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.vm_from_alb_phish) == 0
    error_message = "ASM must get no VM ingress rule for a phishing port it does not bind."
  }

  assert {
    condition     = length(aws_lb_listener.http_redirect) == 1
    error_message = "ASM keeps its :80 HTTP->HTTPS redirect; this change must be a no-op for it."
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

  # The load-bearing assertion. The Azure twin of this module probes phish_port
  # over Tcp because no path on the phish server is guaranteed to answer 200 on
  # a fresh deployment; an ALB cannot do TCP checks, so the equivalent is a
  # permissive matcher. "/" falls through to PhishHandler, which answers 404
  # with no campaign RID -- narrowing this to "200" drains the whole pair.
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

  # A wired listener whose targets are never attached is still an empty pool and
  # a 503. Both nodes of the pair must join the phishing group.
  assert {
    condition     = length(aws_lb_target_group_attachment.vm_phish) == length(aws_instance.vm)
    error_message = "Every SAT VM must be attached to the phishing target group, or the phishing pool stays empty and :80 serves 503."
  }

  # The attachment must override the target-group port with phish_port, not
  # leave traffic going to the admin port.
  assert {
    condition = alltrue([
      for a in aws_lb_target_group_attachment.vm_phish : a.port == 80
    ])
    error_message = "The phishing attachments must send traffic to phish_port (80)."
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
# targets who are by definition somewhere else. Mirrors the coverage the Azure
# twin gained when that bug class was first fixed.
run "phish_allow_list_inherits_admin_list_by_default" {
  command = plan

  variables {
    product       = "sat"
    allowed_cidrs = ["10.0.0.0/8", "192.168.0.0/16"]
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.alb_phish) == 2
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

# ----- The ALB-to-instance hop, on the admin target group -----
#
# An attachment's `port` overrides the target group's, so admin_port has to be
# named in both places. It was a literal 443 here while the target group and its
# health check used admin_port: on SAT the probe passed on 3333, the target
# reported healthy, and real traffic went to a closed port 443. A green target
# group serving nothing reads as an application fault, which is what made it
# expensive. ASM was unaffected only because its admin_port derives to 443.

run "admin_attachments_target_admin_port_on_sat" {
  command = plan

  variables {
    product = "sat"
  }

  assert {
    condition = alltrue([
      for a in aws_lb_target_group_attachment.vm : a.port == 3333
    ])
    error_message = "SAT admin attachments must send traffic to 3333 (config.json admin_server.listen_url); a literal 443 here silently overrides the target group's admin_port and nothing binds 443 on a SAT instance."
  }

  # The health check and the attachment must agree, or a healthy target still
  # serves nothing -- that disagreement was the whole bug.
  assert {
    condition = alltrue([
      for a in aws_lb_target_group_attachment.vm :
      tostring(a.port) == one([for h in aws_lb_target_group.main.health_check : h.port])
    ])
    error_message = "The admin attachment port and the admin health-check port must be the same port, or the probe validates a port that real traffic never reaches."
  }

  assert {
    condition     = length(aws_lb_target_group_attachment.vm) == length(aws_instance.vm)
    error_message = "Every VM must be attached to the admin target group."
  }
}

run "admin_attachments_target_admin_port_on_asm" {
  command = plan

  assert {
    condition = alltrue([
      for a in aws_lb_target_group_attachment.vm : a.port == 443
    ])
    error_message = "ASM admin attachments must send traffic to 443 -- its proxy container publishes 443, so admin_port derives to 443 and the plan must be unchanged for ASM."
  }
}

run "admin_attachments_follow_an_explicit_admin_port_override" {
  command = plan

  # The derivation is not the only path in: a caller can pin admin_port, and the
  # attachment has to follow it rather than the product default.
  variables {
    product    = "sat"
    admin_port = 8443
  }

  assert {
    condition = alltrue([
      for a in aws_lb_target_group_attachment.vm : a.port == 8443
    ])
    error_message = "An explicit admin_port must reach the attachments too, not just the target group."
  }
}
