# VPC endpoints instead of a NAT gateway. The reference diagram in the PDF
# never shows a NAT gateway - just an LB, the private cluster, the VM and the
# backup bucket. NAT is an implementation detail for private-subnet egress,
# not a stated requirement, and it's a flat ~$33/month regardless of traffic.
#
# What actually needs outbound access - this list came from AWS's own
# private-cluster requirements (docs.aws.amazon.com/eks/latest/userguide/
# private-clusters.html), not assumption; a shorter list looked plausible
# first but nodes silently never joined the cluster:
#   - ecr.api / ecr.dkr: pulling the app image from our own ECR repo, and
#     vpc-cni/coredns/kube-proxy from AWS's regional ECR
#   - eks: nodes call the EKS control-plane API to self-configure (fetch
#     endpoint/CA) during boot - distinct from the Kubernetes API server
#     itself, which endpoint_private_access on the cluster already covers
#   - ec2: the EKS-optimized AMI uses EC2 APIs to set the node's DNS name
#   - sts: IRSA pods (alb-controller.tf) exchange tokens via STS - nodes
#     don't need this to join, but the ALB controller pod does
#   - elasticloadbalancing: aws-load-balancer-controller manages ALBs/NLBs
#     through this API
# IMDSv2 never touches the network, and the app only talks to Mongo inside
# this VPC.
#
# Skipped SSM Session Manager into the nodes: not required (the exercise
# asks for kubectl, not node shell access) and the ssm/ssmmessages/ec2messages
# endpoints would've added ~$44/month for nothing this demonstrates.
#
# End result: five interface endpoints plus the free S3 gateway endpoint -
# still cheaper than the NAT gateway it replaces, and private subnets still have no
# path to the public internet at all.

data "aws_region" "current" {}

resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.project_name}-vpc-endpoints"
  description = "HTTPS from the EKS cluster/nodes to interface VPC endpoints"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-vpc-endpoints" }
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_https" {
  security_group_id            = aws_security_group.vpc_endpoints.id
  description                  = "HTTPS from EKS worker nodes"
  referenced_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "vpc_endpoints_all" {
  security_group_id = aws_security_group.vpc_endpoints.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Free: no hourly charge, no data processing charge. Required for ECR image
# layer downloads, which are actually served from S3 behind the scenes.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.project_name}-s3" }
}

locals {
  interface_endpoints = toset([
    "ecr.api",              # authenticate + resolve image manifests
    "ecr.dkr",              # pull image layers
    "sts",                  # IRSA pods (alb-controller.tf) exchange tokens via STS
    "eks",                  # nodes call the EKS control-plane API to self-configure at boot
    "ec2",                  # EKS-optimized AMI uses EC2 APIs to set the node DNS name
    "elasticloadbalancing", # aws-load-balancer-controller manages ALBs/NLBs via this API
  ])
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.project_name}-${replace(each.value, ".", "-")}" }
}
