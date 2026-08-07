output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "alb_controller_ecr_repository_url" {
  description = "Mirror of public.ecr.aws/eks/aws-load-balancer-controller - see ecr.tf."
  value       = aws_ecr_repository.alb_controller.repository_url
}

output "mongo_private_ip" {
  description = "Used to build MONGODB_URI for the Kubernetes secret."
  value       = aws_instance.mongo.private_ip
}

output "mongo_public_ip" {
  description = "SSH here to demonstrate the public-SSH finding."
  value       = aws_instance.mongo.public_ip
}

output "backup_bucket_name" {
  description = "Publicly listable. Try: curl https://<bucket>.s3.amazonaws.com/"
  value       = aws_s3_bucket.backups.id
}

output "vpc_id" {
  value = aws_vpc.main.id
}
