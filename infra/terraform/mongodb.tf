# MongoDB on EC2. Four of the exercise's required weaknesses live in this
# file (outdated AMI, public SSH, over-privileged IAM role, outdated Mongo).
# Don't "fix" any of these without checking the README first - they're
# intentional and the demo depends on them still being there.

# Amazon Linux 2 - support ended June 2026, well over a year behind AL2023.
# Inspector's CVE scan and Security Hub will both flag this.
data "aws_ssm_parameter" "amazon_linux_2" {
  name = "/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2"
}

resource "aws_key_pair" "mongo" {
  count      = var.ssh_public_key == "" ? 0 : 1
  key_name   = "${var.project_name}-mongo"
  public_key = var.ssh_public_key
}

resource "aws_security_group" "mongo" {
  name        = "${var.project_name}-mongo"
  description = "MongoDB VM"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-mongo" }
}

# SSH wide open - second required weakness. Security Hub EC2.13 catches it.
resource "aws_vpc_security_group_ingress_rule" "mongo_ssh_public" {
  security_group_id = aws_security_group.mongo.id
  description       = "SSH open to 0.0.0.0/0 - intentional, see mongodb.tf header"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

# Mongo itself stays locked to EKS nodes only - this is the control the PDF
# actually asks for, not a weakness.
resource "aws_vpc_security_group_ingress_rule" "mongo_from_eks" {
  security_group_id            = aws_security_group.mongo.id
  description                  = "MongoDB from EKS worker nodes only"
  referenced_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  from_port                    = 27017
  to_port                      = 27017
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "mongo_all" {
  security_group_id = aws_security_group.mongo.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# No Secrets Manager here on purpose - var.mongo_app_password comes from a
# single GitHub Actions secret at apply time (variables.tf). Terraform marks
# it sensitive so it's redacted from plan/apply logs, but it still lands in
# state in plaintext like any other TF-managed credential. State bucket
# encryption + access controls are what actually protect it.

resource "aws_iam_role" "mongo" {
  name               = "${var.project_name}-mongo"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "mongo_ssm" {
  role       = aws_iam_role.mongo.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# What the VM actually needs day-to-day: write backups, nothing else. No
# secretsmanager:GetSecretValue - the password reaches it via templatefile()
# below, baked into user_data at apply time instead of fetched at boot.
resource "aws_iam_role_policy" "mongo_runtime" {
  name = "mongo-runtime"
  role = aws_iam_role.mongo.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [aws_s3_bucket.backups.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = ["${aws_s3_bucket.backups.arn}/*"]
      },
    ]
  })
}

# Third weakness: the DB VM can create/modify/terminate any EC2 instance in
# the account, way past what it needs. Customer-managed policy (not inline)
# so Config can actually evaluate it - iam-policy-no-statements-with-full-access
# and Security Hub IAM.21 both fire on this.
resource "aws_iam_policy" "mongo_overprivileged" {
  name        = "${var.project_name}-mongo-ec2-full"
  description = "Grants the database VM full EC2 control - intentional overreach"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "ec2:*"
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "mongo_overprivileged" {
  role       = aws_iam_role.mongo.name
  policy_arn = aws_iam_policy.mongo_overprivileged.arn
}

resource "aws_iam_instance_profile" "mongo" {
  name = "${var.project_name}-mongo"
  role = aws_iam_role.mongo.name
}

# --- the VM itself ---

resource "aws_instance" "mongo" {
  ami                  = data.aws_ssm_parameter.amazon_linux_2.value
  instance_type        = var.mongo_instance_type
  iam_instance_profile = aws_iam_instance_profile.mongo.name
  key_name             = var.ssh_public_key == "" ? null : aws_key_pair.mongo[0].key_name

  # Public subnet + public IP so the open SSH port above is actually
  # reachable, matching the architecture diagram. Security Hub EC2.9 flags
  # instances with public IPs, which is expected here.
  subnet_id                   = aws_subnet.public[0].id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.mongo.id]

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/mongo-userdata.sh.tftpl", {
    aws_region    = var.aws_region
    backup_bucket = aws_s3_bucket.backups.id
    mongo_version = local.mongo_package_version
    mongo_major   = local.mongo_major_version
    database_name = "todo"
    app_username  = "todo_app"
    app_password  = var.mongo_app_password
  })

  tags = { Name = "${var.project_name}-mongodb" }
}

# Fourth and last one: Mongo 6.0.14 shipped January 2024, and 6.0 itself hit
# end of life in July 2025 - well past the "1+ year outdated" bar. Inspector's
# software vulnerability scan surfaces this in Security Hub.
locals {
  mongo_major_version   = "6.0"
  mongo_package_version = "6.0.14"
}
