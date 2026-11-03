# Terraform: EKS cluster and SSM bastion

This directory is the **source of truth** for the classroom VPC, EKS control
plane, managed node group, and SSM bastion. `create.sh` / `destroy.sh` /
`scale-workers.sh` / `connect-bastion.sh` drive it. Do **not** use eksctl or
a CloudFormation bastion stack. ECR stays in CloudFormation under `ecr/`.

## What Terraform creates

| Resource | Setting |
|---|---|
| VPC | `10.0.0.0/16`, DNS hostnames, **no NAT gateway** |
| Subnets | Two public subnets in two AZs, `map_public_ip_on_launch` |
| EKS | Kubernetes `1.35`, public+private endpoint, public API `/32` |
| Workers | One On-Demand `t3.small` (max 2), AL2023, 20 GiB gp3, IMDSv2 |
| Bastion | `t4g.nano` ARM, SSM only, no inbound ports, 8 GiB gp3 |
| Tags | Provider `default_tags`: **`env=test-eks`** on every taggable resource |
| ALB IRSA | EKS OIDC provider + IAM role for `kube-system/aws-load-balancer-controller` |

IAM roles, the node launch template, EKS access entry (bastion =
cluster-admin), the 443 rule from the bastion SG to the cluster SG, EKS OIDC,
and the AWS Load Balancer Controller IRSA role are included.

ECR repositories stay in CloudFormation (`ecr/create-repositories.sh`) and
are still tagged `env=test-eks`.

## Commands (normally use the shell wrappers)

From the **EKS** directory, after AWS credentials work:

```bash
mkdir -p .state
# create.sh writes .state/lab.tfvars then:
terraform -chdir=terraform init
terraform -chdir=terraform apply -var-file=../.state/lab.tfvars
```

State file: `.state/terraform.tfstate` (gitignored). Do not commit it.

Activate the `env` cost allocation tag in Billing, then filter Cost Explorer
by `env=test-eks` after class.
