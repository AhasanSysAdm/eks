output "cluster_name" {
  value       = aws_eks_cluster.lab.name
  description = "EKS cluster name."
}

output "cluster_endpoint" {
  value       = aws_eks_cluster.lab.endpoint
  description = "EKS API endpoint (public access limited to admin_cidr)."
}

output "vpc_id" {
  value       = aws_vpc.lab.id
  description = "Lab VPC id (used for extra cost tags)."
}

output "bastion_instance_id" {
  value       = aws_instance.bastion.id
  description = "SSM target for connect-bastion.sh."
}

output "bastion_role_arn" {
  value       = aws_iam_role.bastion.arn
  description = "Bastion instance role (cluster-admin access entry)."
}

output "node_group_name" {
  value       = aws_eks_node_group.workers.node_group_name
  description = "Managed node group name (demo-workers)."
}

output "alb_controller_role_arn" {
  value       = aws_iam_role.alb_controller.arn
  description = "IRSA role for AWS Load Balancer Controller (install-alb-controller.sh)."
}
