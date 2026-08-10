# Only the S3 gateway endpoint remains here. The six interface endpoints
# (ecr.api, ecr.dkr, sts, eks, ec2, elasticloadbalancing) that used to cover
# private-subnet egress were replaced by a single NAT gateway (network.tf) -
# cheaper (~$0.045/hr vs ~$0.12/hr for six endpoints across 2 AZs) and far
# fewer moving parts. The S3 gateway endpoint stays anyway: it's free (no
# hourly charge, no data processing charge) and keeps ECR's S3-backed image
# layer pulls off the NAT gateway entirely.

data "aws_region" "current" {}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.project_name}-s3" }
}
