output "vpc_id" {
  description = "VPC ID. Pass to var.vpc_id on workload modules."
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  value = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs (one per AZ). Pass to var.public_subnet_ids on ha-hot-hot / unlimited-scale."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (one per AZ). Pass to var.private_subnet_ids on ha-hot-hot / unlimited-scale, or var.subnet_id (use one) on single-vm."
  value       = aws_subnet.private[*].id
}

output "db_subnet_ids" {
  description = "Isolated DB subnet IDs. Currently unused by the workload modules (which place RDS in private subnets) but useful if you wire up your own DB."
  value       = aws_subnet.db[*].id
}

output "availability_zones" {
  value = data.aws_availability_zones.available.names
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs (one per AZ), or empty list if enable_nat_gateway = false."
  value       = aws_nat_gateway.main[*].id
}

output "nat_gateway_public_ips" {
  description = "Public Elastic IPs of the NAT gateways. Allowlist these on external scan targets you control so scans can reach them."
  value       = aws_eip.nat[*].public_ip
}

output "internet_gateway_id" {
  value = aws_internet_gateway.main.id
}
