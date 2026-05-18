output "alb_dns_name" { value = aws_lb.main.dns_name }
output "alb_zone_id" { value = aws_lb.main.zone_id }
output "alb_arn" { value = aws_lb.main.arn }

output "autoscaling_group_name" { value = aws_autoscaling_group.main.name }
output "autoscaling_group_arn" { value = aws_autoscaling_group.main.arn }
output "launch_template_id" { value = aws_launch_template.main.id }

output "db_endpoint" { value = aws_db_instance.primary.endpoint }
output "db_read_endpoints" { value = aws_db_instance.replica[*].endpoint }
output "db_secret_arn" { value = aws_secretsmanager_secret.db.arn }

output "sns_alerts_topic_arn" { value = aws_sns_topic.alerts.arn }
output "ami_id" { value = data.aws_ami.hailbytes.id }
output "alb_access_logs_bucket" { value = aws_s3_bucket.alb_logs.id }
