# IRSA for AWS Load Balancer Controller (ALB Ingress in cicd/pipeline.sh).
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.lab.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[length(data.tls_certificate.eks_oidc.certificates) - 1].sha1_fingerprint]
  url             = aws_eks_cluster.lab.identity[0].oidc[0].issuer
}

data "aws_iam_policy_document" "alb_controller_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
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
  name               = "${var.cluster_name}-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_assume.json
}

resource "aws_iam_role_policy" "alb_controller" {
  name   = "AWSLoadBalancerControllerIAMPolicy"
  role   = aws_iam_role.alb_controller.id
  policy = file("${path.module}/aws-load-balancer-controller-iam-policy.json")
}
