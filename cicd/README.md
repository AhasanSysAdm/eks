# Bash CI/CD demo (nginx + ALB)

After `bash create.sh`, this pipeline:

1. Pulls `nginx:1.28-alpine`
2. Bakes **app version N** into the image
3. Pushes `…/nginx-cicd:vN` to ECR
4. Applies a Deployment, ClusterIP Service, and Ingress
5. The Ingress annotation creates an **internet-facing AWS ALB**
6. Prints the body from the ALB URL (expect `app version N`)

Re-run with `2` to push a new tag and show **app version 2**.

ALB is **billable**. `destroy.sh` removes the EKS/VPC stack; delete leftover ALBs in EC2 → Load Balancers if Ingress cleanup failed. Tag: `env=test-eks`.

## Prerequisites

- Cluster from `create.sh` (re-apply so Terraform has the ALB controller IAM role + EKS OIDC)
- Workstation: AWS CLI, Docker (linux/amd64), kubectl, Helm 3, curl
- `aws eks update-kubeconfig --name academy-eks-demo --alias academy-eks-demo`

Do not build on the 512 MiB bastion.

```bash
cd /path/to/EKS
aws eks update-kubeconfig --region us-east-2 --name academy-eks-demo --alias academy-eks-demo
bash cicd/pipeline.sh 1
# wait until it prints: app version 1
bash cicd/pipeline.sh 2
# prints: app version 2
```

ECR tags are immutable: use a new version string each run (`1`, `2`, `3`, …).
If GitHub Actions already published `nginx-cicd:vN`, `pipeline.sh` deploys that
tag and does not rebuild.

Optional CI (image only, no kubectl): GitHub **Actions > Publish nginx CI/CD
image** after [OIDC bootstrap](../ecr/README.md).
