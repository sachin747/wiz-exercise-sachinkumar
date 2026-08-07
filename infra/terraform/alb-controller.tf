# IAM/IRSA side of the AWS Load Balancer Controller. The controller itself
# (Deployment, RBAC, webhooks, CRDs) lives in k8s/alb-controller.yaml - see
# that file's header for how it was produced and why it isn't hand-written
# here alongside everything else.

# IRSA: the controller's pod authenticates as this role via its Kubernetes
# ServiceAccount token, no long-lived AWS keys in the cluster. Needs the
# cluster's own OIDC provider registered with IAM first - EKS doesn't do
# this automatically.
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
}

data "aws_iam_policy_document" "alb_controller_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    # Scoped to the exact ServiceAccount the controller runs as - anything
    # else presenting a token from this OIDC provider can't assume this role.
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "${var.project_name}-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_assume.json
}

# files/alb-controller-iam-policy.json is copied verbatim from
# kubernetes-sigs/aws-load-balancer-controller (docs/install/iam_policy.json,
# tag v2.13.0 - matches the chart version rendered into
# k8s/alb-controller.yaml). Not hand-written: it's ~250 lines covering ALB,
# target group and security group management, easy to get subtly wrong by
# guessing, so it's pulled straight from upstream instead. Re-copy it if the
# controller version ever gets bumped.
resource "aws_iam_policy" "alb_controller" {
  name   = "${var.project_name}-alb-controller"
  policy = file("${path.module}/files/alb-controller-iam-policy.json")
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# app.yml discovers this by name (same pattern as the ECR repo and the Mongo
# VM) and patches it into the ServiceAccount annotation - see
# k8s/alb-controller-serviceaccount.yaml.
output "alb_controller_role_arn" {
  value = aws_iam_role.alb_controller.arn
}
