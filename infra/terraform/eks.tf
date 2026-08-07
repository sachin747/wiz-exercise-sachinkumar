# Amazon EKS - control plane plus a managed node group, private subnets only.

# --- IAM ---

data "aws_iam_policy_document" "eks_cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.project_name}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "${var.project_name}-eks-node"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_node" {
  # No AmazonSSMManagedInstanceCore: SSM Session Manager into nodes isn't
  # required by the exercise (kubectl is), and there's no SSM VPC endpoint
  # to reach it through anyway -- see vpc-endpoints.tf.
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])
  role       = aws_iam_role.eks_node.name
  policy_arn = each.value
}

# --- control plane ---

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.eks_cluster.arn

  # Covers the "configure control plane audit logging" requirement - all five
  # streams go to CloudWatch and feed GuardDuty's EKS Audit Log Monitoring.
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids = aws_subnet.private[*].id

    endpoint_private_access = true

    # Public endpoint stays open because GitHub-hosted runners don't have a
    # fixed egress IP to allowlist. Still SigV4 + EKS Access Entries under
    # the hood, not anonymous access. Not one of the PDF's required
    # weaknesses, just a lab tradeoff - see the README TODO list.
    endpoint_public_access = true
    public_access_cidrs    = ["0.0.0.0/0"]
  }

  # The log group must exist first, otherwise EKS creates it implicitly with
  # never-expiring retention and Terraform then fails on "already exists".
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster,
    aws_cloudwatch_log_group.eks,
  ]
}

resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 90
}

# Optional second admin so kubectl works from laptop as well as from CI.
resource "aws_eks_access_entry" "admin" {
  count         = var.cluster_admin_role_arn == "" ? 0 : 1
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.cluster_admin_role_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  count         = var.cluster_admin_role_arn == "" ? 0 : 1
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.cluster_admin_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}

# --- worker nodes, private subnets only ---

resource "aws_launch_template" "node" {
  name_prefix = "${var.project_name}-node-"

  # IMDSv2 required, hop limit 1 - a compromised container can't reach the
  # node's instance credentials through the metadata endpoint.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.project_name}-node" }
  }
}

resource "aws_eks_node_group" "app" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "application"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = [var.node_instance_type]
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = 1
    max_size     = 4
  }

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  # There is no NAT gateway (see vpc-endpoints.tf) -- nodes must be able to
  # resolve and reach ECR through the interface endpoints before they can
  # pull kube-proxy/vpc-cni/coredns and become Ready, so the endpoints have
  # to exist first.
  depends_on = [
    aws_iam_role_policy_attachment.eks_node,
    aws_vpc_endpoint.interface,
    aws_vpc_endpoint.s3,
  ]
}

# --- add-ons ---

resource "aws_eks_addon" "core" {
  # No eks-pod-identity-agent - nothing here uses EKS Pod Identity now that
  # the ALB controller (its only consumer) is gone.
  for_each = toset(["vpc-cni", "coredns", "kube-proxy"])

  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = each.value
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # Turns on the VPC CNI's NetworkPolicy enforcement. Without this,
  # k8s/network-policy.yaml applies cleanly but does nothing - a
  # NetworkPolicy object is inert unless the CNI enforces it, and EKS's
  # default vpc-cni addon doesn't out of the box.
  configuration_values = each.value == "vpc-cni" ? jsonencode({ enableNetworkPolicy = "true" }) : null

  depends_on = [aws_eks_node_group.app]
}

# --- load balancer exposure ---
#
# Covers "exposed via ... a Kubernetes ingress and CSP load balancer",
# literally this time. The AWS Load Balancer Controller (alb-controller.tf
# for the IAM/IRSA side, k8s/alb-controller.yaml + k8s/ingress.yaml for the
# Kubernetes side) watches Ingress objects and provisions a real ALB for
# each one. Public subnets are already tagged kubernetes.io/role/elb = 1
# (network.tf), which is how the controller auto-discovers where to put it
# - no manual subnet wiring needed here.
#
# Previously this was a bare Service type: LoadBalancer (an NLB, no
# controller required). Switched over once a real Ingress resource became
# worth the extra moving part - see the README for the trade-off history.
