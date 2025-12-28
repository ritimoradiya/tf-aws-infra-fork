output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of public subnets"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of private subnets"
  value       = aws_subnet.private[*].id
}

output "application_security_group_id" {
  description = "ID of application security group"
  value       = aws_security_group.application.id
}

output "ec2_instance_id" {
  description = "ID of EC2 instance"
  value       = aws_instance.webapp.id
}

output "ec2_instance_public_ip" {
  description = "Public IP of EC2 instance"
  value       = aws_instance.webapp.public_ip
}