output "alb_dns_name" {
  description = "Public DNS name of the ALB. Point your CNAME / Route53 alias here."
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Hosted zone ID of the ALB, for Route 53 alias records."
  value       = aws_lb.main.zone_id
}

output "alb_arn" {
  value = aws_lb.main.arn
}

output "instance_ids" {
  description = "EC2 instance IDs of the two active/active VMs."
  value       = aws_instance.vm[*].id
}

output "db_endpoint" {
  description = "RDS endpoint (host:port). Connection details are in Secrets Manager."
  value       = aws_db_instance.main.endpoint
}

output "db_secret_arn" {
  description = "Secrets Manager ARN containing Postgres credentials."
  value       = aws_secretsmanager_secret.db.arn
}

output "db_instance_arn" {
  value = aws_db_instance.main.arn
}

output "ami_id" {
  value = data.aws_ami.hailbytes.id
}

output "security_group_ids" {
  value = {
    alb = aws_security_group.alb.id
    vm  = aws_security_group.vm.id
    db  = aws_security_group.db.id
  }
}
