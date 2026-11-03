# Private ECR images and Argo CD CI/CD

Run from the EKS directory in Bash/WSL with AWS CLI v2, Docker (running Linux
engine), and Python 3 installed in that environment. No AWS credentials belong
in the repository. These commands create billable ECR storage. Repositories are tagged
`env=test-eks` (same cost-allocation tag as the EKS cluster and bastion).

## 1. Create repositories and publish images

ECR is separate from `create.sh` (Terraform only). Create repositories with:

```bash
bash ecr/create-repositories.sh
bash ecr/build-push.sh demo-1
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
python3 ecr/update-images.py \
  --registry "$ACCOUNT.dkr.ecr.us-east-2.amazonaws.com" \
  --cluster academy-eks-demo --tag demo-1
```

The script builds three **linux/amd64** images based on NGINX, PHP/Apache,
and BusyBox, matching the x86 EKS workers. The stack also creates
`${CLUSTER_NAME}/nginx-cicd` for the [bash ALB demo](../cicd/README.md); that
image is built by `cicd/pipeline.sh` or `.github/workflows/publish-nginx-cicd.yaml`,
not by `build-push.sh`. It preserves the upstream entrypoints.
The web page and PHP code remain ConfigMaps, so their lessons still work.
Use a NEW tag for every publication: repository tags are immutable.
Upstream base tags are versioned but not digest-pinned; pin their digests in the
script if reproducible builds are needed. System components such as Argo CD,
Metrics Server, and VPA controllers still use their upstream images.

The caller needs ECR upload permissions plus `ecr:GetAuthorizationToken`.
The token is passed via stdin and stored only in a temporary Docker config,
removed on exit. Docker must be running; do not build on the 512 MiB bastion.

After updating image references:

```bash
kubectl apply -f hpa/demo.yaml
# Apply these only during their respective lessons:
kubectl apply -f hpa/load.yaml
kubectl apply -f hpa/vpa-demo.yaml
helm upgrade --install classroom argo/chart -n helm-demo --create-namespace --wait
kubectl -n hpa-demo get pods
kubectl -n hpa-demo describe pods
```

The VPA controllers/CRD must be installed before applying the VPA file.
Delete an old load Job before reapplying a changed image (Job templates are
immutable). Updating the HPA file resets its declared replicas temporarily.

## 2. How authentication works

- **Push:** instructor AWS identity, or a GitHub OIDC role, obtains an ECR token.
- **Pull:** kubelet uses the **EKS worker node IAM role** and its
  `AmazonEC2ContainerRegistryReadOnly` policy. This is attached in
  [terraform/eks.tf](../terraform/eks.tf).
- **Argo CD:** reads Git and submits Kubernetes manifests. It does NOT need the
  ECR password or an AWS push role to deploy these images.

No `imagePullSecrets`, static AWS keys, or periodically refreshed Kubernetes
passwords are needed for this same-account managed-node-group lab. IRSA/Pod
Identity on an application ServiceAccount is not a substitute for node image
pull permissions. Cross-account ECR additionally needs repository policies.
Nodes need network connectivity to ECR/S3; these public nodes use internet
egress. Existing workers must already have the ECR policy or have it attached
by their administrator; changing Terraform later does not retrofit an
already-created node role unless you re-apply.

## 3. Bootstrap GitHub Actions OIDC

Publish the contents of EKS as the **root of your own GitHub repository**.
The included `.github/workflows/publish-gitops.yaml` must be at the repository
root. Do not upload `.state`, credentials, kubeconfig files, or unrelated code.
Edit both URLs in `argo/application.yaml` to match that repository.

Check whether the AWS account already has the GitHub OIDC provider:

```bash
aws iam list-open-id-connect-providers
```

Set `CreateProvider=false` below if
`oidc-provider/token.actions.githubusercontent.com` already exists. Never
delete or replace another team's provider.

```bash
aws cloudformation deploy \
  --stack-name academy-eks-demo-github-oidc \
  --template-file ecr/github-oidc.yaml \
  --capabilities CAPABILITY_IAM \
  --tags Key=env,Value=test-eks \
  --parameter-overrides ClusterName=academy-eks-demo \
    GitHubRepository=YOUR-OWNER/YOUR-REPO CreateProvider=true

aws cloudformation describe-stacks \
  --stack-name academy-eks-demo-github-oidc \
  --query "Stacks[0].Outputs[?OutputKey=='PublisherRoleArn'].OutputValue | [0]" \
  --output text
```

In GitHub **Settings > Secrets and variables > Actions > Variables**, create
`AWS_ECR_PUBLISH_ROLE_ARN` using the output. This ARN is not a secret.
Create the ECR stack first (`bash ecr/create-repositories.sh`) so `nginx-cicd`
exists; the OIDC role cannot create repositories.

Optional: **Actions > Publish nginx CI/CD image > Run workflow** with `1`, then
`2`. That only pushes `nginx-cicd:vN`. Deploy and curl the ALB from the
workstation with `bash cicd/pipeline.sh 1` then `bash cicd/pipeline.sh 2`
(skips rebuild if the tag already exists).
Enable Actions **Read and write permissions** for `GITHUB_TOKEN` so the workflow
can commit image versions. Main-branch protection that requires PRs will reject
the push; use a PR-based promotion workflow for such repositories rather than
bypassing protection. The role trust permits only this repository's `main`
branch; it does not trust fork PRs or arbitrary repositories.

## 4. Pipeline demonstration

```text
Push Dockerfile change to main / manually Run workflow
  -> GitHub OIDC authenticates to AWS
  -> Build three images -> Push unique immutable ECR tags
  -> Commit chart + HPA/VPA image references back to main
  -> Argo CD sees Git change -> Sync -> EKS kubelet pulls from private ECR
```

Install Argo CD and apply its Application using [the Argo lesson](../argo/README.md).
Then open GitHub **Actions > Publish ECR images and update GitOps > Run workflow**
on `main`. The CI job does not need EKS credentials or public API access.
The workflow only triggers on image-source/workflow changes, not its own
values commit. If Git advanced during the build, push fails rather than
overwriting anyone's changes; rerun the workflow.

```bash
kubectl -n argocd get application classroom -w
kubectl -n gitops-demo get pods
kubectl -n gitops-demo get deployment gitops-demo \
  -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
```

The current Argo Application manages the **web chart**. The pipeline also
updates HPA/VPA YAML in Git, but those lessons are intentionally applied
manually, not run concurrently on tiny workers.

## 5. Cleanup

Disable the GitHub workflow before deleting the lab to prevent publication
during teardown. `destroy.sh` only runs `terraform destroy` (VPC/EKS/nodes/bastion).
It does **not** delete ECR or the optional GitHub OIDC stack.

If the nginx ALB demo is running, delete it first so leftover ALBs do not block
VPC deletion:

```bash
kubectl delete namespace cicd-demo --ignore-not-found
```

Do not delete a GitHub OIDC provider used by other teams. If this lab created
the provider and nothing else needs it:

```bash
aws cloudformation delete-stack --stack-name academy-eks-demo-github-oidc
aws cloudformation wait stack-delete-complete --stack-name academy-eks-demo-github-oidc
```

ECR (including images):

```bash
aws cloudformation delete-stack --stack-name academy-eks-demo-ecr
aws cloudformation wait stack-delete-complete --stack-name academy-eks-demo-ecr
```

`${CLUSTER_NAME}/nginx-cicd` is in the ECR stack. If the bash pipeline created
that repository before `create-repositories.sh`, delete the leftover:

```bash
aws ecr delete-repository --repository-name academy-eks-demo/nginx-cicd --force
```

## Validation status

Local checks can validate shell syntax, templates, image-reference updates,
Helm rendering, and mocked lifecycle calls. Real building, ECR uploads, GitHub
OIDC assumption, and EKS pulls require a running Docker engine and live tests.
