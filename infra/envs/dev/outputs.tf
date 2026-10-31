output "alb_dns_name" {
  description = "Nom DNS public de l'Application Load Balancer"
  value       = module.web_stack.alb_dns_name
}

output "asg_name" {
  description = "Groupe d'auto-scaling, utilise par les scripts de fin de journee"
  value       = module.web_stack.asg_name
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "public_subnets" {
  value = module.network.public_subnets
}
