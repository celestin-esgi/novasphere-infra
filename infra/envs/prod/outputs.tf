output "alb_dns_name" {
  description = "Nom DNS public de l'Application Load Balancer"
  value       = aws_lb.web.dns_name
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "public_subnets" {
  value = module.network.public_subnets
}
