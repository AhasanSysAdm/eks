data "aws_ssm_parameter" "al2023_arm" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_iam_policy_document" "bastion_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "bastion_describe" {
  statement {
    actions   = ["eks:DescribeCluster"]
    resources = [aws_eks_cluster.lab.arn]
  }
}

resource "aws_iam_role" "bastion" {
  name               = "${var.cluster_name}-bastion"
  assume_role_policy = data.aws_iam_policy_document.bastion_assume.json
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "bastion_describe" {
  name   = "DescribeLabCluster"
  role   = aws_iam_role.bastion.id
  policy = data.aws_iam_policy_document.bastion_describe.json
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.cluster_name}-bastion"
  role = aws_iam_role.bastion.name
}

resource "aws_security_group" "bastion" {
  name        = "${var.cluster_name}-bastion"
  description = "SSM-only bastion; no inbound SSH"
  vpc_id      = aws_vpc.lab.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-bastion-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "bastion_to_api" {
  security_group_id            = aws_eks_cluster.lab.vpc_config[0].cluster_security_group_id
  referenced_security_group_id = aws_security_group.bastion.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Bastion to EKS API"
}

resource "aws_eks_access_entry" "bastion" {
  cluster_name  = aws_eks_cluster.lab.name
  principal_arn = aws_iam_role.bastion.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "bastion_admin" {
  cluster_name  = aws_eks_cluster.lab.name
  principal_arn = aws_iam_role.bastion.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.bastion]
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ssm_parameter.al2023_arm.value
  instance_type               = "t4g.nano"
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  associate_public_ip_address = true
  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    region       = var.region
    cluster_name = var.cluster_name
  })
  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = 8
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
    tags = {
      Name               = "${var.cluster_name}-bastion"
      (var.cost_tag_key) = var.cost_tag_value
      Project            = var.cluster_name
    }
  }

  tags = {
    Name = "${var.cluster_name}-bastion"
  }

  depends_on = [
    aws_iam_role_policy_attachment.bastion_ssm,
    aws_iam_role_policy.bastion_describe,
    aws_eks_access_policy_association.bastion_admin,
    aws_internet_gateway.lab,
  ]
}
