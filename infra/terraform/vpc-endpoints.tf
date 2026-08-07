# VPC endpoints instead of a NAT gateway. The reference diagram in the PDF
# never shows a NAT gateway - just an LB, the private cluster, the VM and the
# backup bucket. NAT is an implementation detail for private-subnet egress,
# not a stated requirement, and it's a flat ~$33/month regardless of traffic.
#
# What actually needs outbound access, checked against this repo rather than
# assumed: pulling the app image from our own ECR repo, pulling
# vpc-cni/coredns/kube-proxy from AWS's regional ECR (not Docker Hub, not the
# public gallery), and STS - every node's kubelet authenticates to the
# cluster with a short-lived IAM token (aws-iam-authenticator, under the
# hood an STS GetCallerIdentity call), so nodes never actually register as
# Kubernetes nodes without a path to STS, even though the EC2 instances
# themselves boot and pass health checks fine. EKS API itself is already
# reachable privately, IMDSv2 never touches the network, and the app only
# talks to Mongo inside this VPC.
#
# Skipped SSM Session Manager into the nodes: not required (the exercise
# asks for kubectl, not node shell access) and the ssm/ssmmessages/ec2messages
# endpoints would've added ~$44/month for nothing this demonstrates.
#
# End result: ECR (api + dkr) + STS, plus the free S3 gateway endpoint -
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
    "ecr.api", # authenticate + resolve image manifests
    "ecr.dkr", # pull image layers
    "sts",     # kubelet's IAM auth token exchange - nodes can't join without this
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
