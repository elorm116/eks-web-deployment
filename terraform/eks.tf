module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name    = var.cluster_name
  kubernetes_version = "1.35"

  addons = {
    coredns                = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy             = {}
    vpc-cni                = {
      before_compute = true
    }
  }

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  endpoint_public_access = true

  enable_cluster_creator_admin_permissions = true


  eks_managed_node_groups = {
    web = {
      min_size       = 1
      max_size       = 4
      desired_size   = var.desired_nodes
      instance_types = [var.node_instance_type]
    }
  }

  tags = {
    Project = "eks-web-deployment"
  }
}
