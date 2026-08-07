# Container registry for the app image. Two preventative controls here:
# IMMUTABLE tags mean a pushed tag can't be overwritten later, so what CI
# scanned is exactly what runs in the cluster. scan_on_push turns on ECR's
# basic scanning, which shows up in Security Hub as ECR.1/Inspector findings.

resource "aws_ecr_repository" "app" {
  name                 = var.project_name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the newest 20 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = { type = "expire" }
    }]
  })
}

# Mirror for the ALB controller image. It ships from public.ecr.aws by
# default (see k8s/alb-controller.yaml), which has no VPC endpoint - AWS
# doesn't offer PrivateLink for ECR Public at all, so nodes in these
# NAT-less private subnets can never pull it directly. infra.yml copies the
# real image here once (skips the copy if the tag already exists), and the
# manifest points at this repo instead of the public one.
resource "aws_ecr_repository" "alb_controller" {
  name                 = "${var.project_name}-alb-controller"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}
