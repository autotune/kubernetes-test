data "aws_eks_cluster" "default" {
  name = module.badams.cluster_id
}

data "aws_eks_cluster_auth" "default" {
  name = module.badams.cluster_id
}

data "aws_availability_zones" "available" {
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 2.6"

  name                 = "badams"
  cidr                 = "10.16.0.0/16"
  azs                  = ["us-east-1a", "us-east-1b", "us-east-1d"]
  private_subnets      = ["10.16.8.0/24", "10.16.9.0/24", "10.16.4.0/24"]
  public_subnets       = ["10.16.5.0/24", "10.16.6.0/24", "10.16.7.0/24"]
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/cluster/badams-prod" = "shared"
    "kubernetes.io/role/elb"             = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/badams-prod" = "shared"
    "kubernetes.io/role/internal-elb"    = "1"
  }
}

resource "aws_security_group" "badams" {
  name        = "badams-eks-prod"
  description = "badams eks security group"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_security_group_rule" "ec2_ingress_all" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  security_group_id = aws_security_group.badams.id
  cidr_blocks       = ["10.16.0.0/16"]
}

module "badams" {
  source          = "terraform-aws-modules/eks/aws"
  cluster_name    = "badams-prod"
  cluster_version = "1.19"
  manage_aws_auth = true
  subnets         = module.vpc.public_subnets
  vpc_id          = module.vpc.vpc_id

  worker_groups = [
    {
      instance_type = "t2.large"
      asg_max_size  = 3
    }
  ]

  node_groups_defaults = {
    ami_type  = "AL2_x86_64"
    disk_size = 50
  }

  node_groups = {
    example = {
      desired_capacity = 1
      max_capacity     = 2
      min_capacity     = 1

      instance_type = "t2.large"
      k8s_labels = {
        Environment = "test"
        GithubRepo  = "terraform-aws-eks"
        GithubOrg   = "terraform-aws-modules"
      }
      additional_tags = {
        Name      = "badams"
        Env       = "Prod"
        Terraform = "True"
      }
    }
  }
  map_users = [
    {
      userarn  = "arn:aws:iam::477962946895:user/badams"
      username = "badams"
      groups   = ["system:masters"]
    }
  ]
}

data "aws_route53_zone" "selected" {
  name = "badams.ninja."
}

/* resource "aws_route53_record" "root" {
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = "badams-prod"
  type    = "A"
  ttl     = "300"
  records = ["13.248.207.43"]
} */

provider "acme" {
  server_url = "https://acme-v02.api.letsencrypt.org/directory"
}

resource "tls_private_key" "platform_domain_administrator" {
  algorithm = "RSA"
}

resource "acme_registration" "platform_domain_administrator" {
  account_key_pem = tls_private_key.platform_domain_administrator.private_key_pem
  email_address   = "b+acme@contrasting.org"
}

resource "tls_private_key" "platform_domain_csr" {
  algorithm = "RSA"
}

resource "tls_cert_request" "platform_domain" {
  key_algorithm   = "RSA"
  private_key_pem = tls_private_key.platform_domain_csr.private_key_pem

  subject {
    common_name = "*.badams.ninja"
  }
}

resource "acme_certificate" "platform_domain" {
  account_key_pem         = acme_registration.platform_domain_administrator.account_key_pem
  certificate_request_pem = tls_cert_request.platform_domain.cert_request_pem

  dns_challenge {
    provider = "route53"
  }
}

resource "aws_acm_certificate" "cert" {
  domain_name       = "badams.ninja"
  validation_method = "DNS"

  tags = {
    Environment = "Prod"
  }
}

resource "aws_db_subnet_group" "badams" {
  name       = "main"
  subnet_ids = module.vpc.private_subnets

  tags = {
    Name = "badams-prod serverless"
  }
}


# Use the last snapshot of the dev database before it was destroyed to create
# a new dev database.
resource "aws_rds_cluster" "aurora" {
  cluster_identifier   = "badams-eks-prod"
  snapshot_identifier  = aws_db_cluster_snapshot.badams.id
  db_subnet_group_name = aws_db_subnet_group.badams.id
  engine               = "aurora-postgresql"
  engine_version       = "10.14"
  engine_mode          = "serverless"

  vpc_security_group_ids = [aws_security_group.badams.id]
  scaling_configuration {
    auto_pause               = true
    max_capacity             = 8
    min_capacity             = 2
    seconds_until_auto_pause = 300
    timeout_action           = "ForceApplyCapacityChange"
  }

  final_snapshot_identifier = "badams-eks-prod-final"

  lifecycle {
    ignore_changes = [snapshot_identifier]
  }

  depends_on = [aws_db_cluster_snapshot.badams]
}

resource "aws_eip" "lb" {
  count = 3
  vpc   = true
  tags = {
    Terraform = "True"
    Env       = "Prod"
    App       = "badams"
  }
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.default.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.default.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.default.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.default.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.default.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.default.token
  }
}

resource "local_file" "kubeconfig" {
  sensitive_content = templatefile("${path.module}/kubeconfig.tpl", {
    cluster_name = module.badams.cluster_id,
    clusterca    = data.aws_eks_cluster.default.certificate_authority[0].data,
    endpoint     = data.aws_eks_cluster.default.endpoint,
  })
  filename = "./kubeconfig-${module.badams.cluster_id}"
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "kubernetes_namespace" "badams" {
  metadata {
    name = "badams"
  }
}
