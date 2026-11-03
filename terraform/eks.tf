data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "cluster_vpc" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

resource "aws_eks_cluster" "lab" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = aws_subnet.public[*].id
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = [var.admin_cidr]
  }

  tags = {
    Name = var.cluster_name
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_iam_role_policy_attachment.cluster_vpc,
  ]
}

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_launch_template" "workers" {
  name_prefix = "${var.cluster_name}-workers-"
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name               = "${var.cluster_name}-worker"
      (var.cost_tag_key) = var.cost_tag_value
      Project            = var.cluster_name
    }
  }
  tag_specifications {
    resource_type = "volume"
    tags = {
      Name               = "${var.cluster_name}-worker"
      (var.cost_tag_key) = var.cost_tag_value
      Project            = var.cluster_name
    }
  }
  tag_specifications {
    resource_type = "network-interface"
    tags = {
      Name               = "${var.cluster_name}-worker"
      (var.cost_tag_key) = var.cost_tag_value
      Project            = var.cluster_name
    }
  }
}

resource "aws_eks_node_group" "workers" {
  cluster_name    = aws_eks_cluster.lab.name
  node_group_name = "demo-workers"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.public[*].id
  ami_type        = "AL2023_x86_64_STANDARD"
  instance_types  = ["t3.small"]
  capacity_type   = "ON_DEMAND"

  scaling_config {
    desired_size = var.desired_size
    min_size     = 1
    max_size     = 2
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.workers.id
    version = aws_launch_template.workers.latest_version
  }

  labels = {
    env = var.cost_tag_value
  }

  depends_on = [
    aws_eks_cluster.lab,
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
}
