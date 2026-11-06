data "aws_ami" "debian" {
  most_recent = true
  owners      = ["136693071363"]

  filter {
    name   = "name"
    values = ["debian-12-amd64-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Learner Lab : la creation de roles IAM est interdite, on consomme le profil fourni
data "aws_iam_instance_profile" "lab" {
  name = "LabInstanceProfile"
}

locals {
  name = "novasphere-${var.environment}-${var.owner}"
}

resource "aws_ssm_parameter" "db_password" {
  name             = "/novasphere/${var.environment}/db_password"
  type             = "SecureString"
  value_wo         = var.db_password
  value_wo_version = 1
}

module "network" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name
  cidr = "10.0.0.0/16"

  azs            = ["us-east-1a", "us-east-1b"]
  public_subnets = ["10.0.1.0/24", "10.0.2.0/24"]

  enable_nat_gateway      = false
  map_public_ip_on_launch = true
}

module "web_stack" {
  source = "git::https://github.com/celestin-esgi/terraform-aws-web-stack.git?ref=v1.1.0"

  name       = local.name
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.public_subnets

  ami_id           = data.aws_ami.debian.id
  instance_type    = var.instance_type
  desired_capacity = var.desired_capacity

  user_data_base64 = base64encode(templatefile("${path.module}/bootstrap.sh", {
    environment = var.environment
  }))

  iam_instance_profile_name = data.aws_iam_instance_profile.lab.name
}
