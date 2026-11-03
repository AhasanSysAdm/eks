# Tiny EKS classroom lab

This directory is a sibling of `YAML`, not inside it. Nothing provisions AWS
until you explicitly run a provisioning script. **Terraform** (`terraform/`)
is the source of truth for the VPC, EKS cluster, node group, and SSM bastion.
CloudFormation is used only for private ECR repositories
(`ecr/create-repositories.sh`) and the optional GitHub OIDC stack.
`create.sh` checks AWS credentials (and prompts if they are missing), then
runs `terraform apply`. See
[ECR images and CI/CD](ecr/README.md) for building/pushing all application
images, IAM-based pulls, and the GitHub Actions-to-Argo CD pipeline.
Creating repositories does not build images; run the publishing script or
workflow, then update the image references before deploying the ECR variants.

## What this creates

| Component | Lab setting |
|---|---|
| Provisioning | Terraform for VPC/EKS/nodes/bastion; CloudFormation for ECR only |
| Region | `us-east-2` (Ohio) |
| EKS | One normal managed control plane, Kubernetes `1.35` |
| Worker | One On-Demand `t3.small`, 2 vCPU / 2 GiB, 20 GiB gp3 |
| Optional second worker | Manually enabled for VPA/Argo CD, maximum two |
| Bastion | One ARM `t4g.nano`, 2 vCPU / 512 MiB, 8 GiB gp3 |
| Bastion login | SSM Session Manager; no SSH key and no inbound ports |
| Network | Dedicated Terraform VPC/subnets, public workers, no NAT gateway |
| Kubernetes API | Private endpoint enabled; public access restricted to your IPv4 `/32` |
| Demos | HPA, VPA, Helm, Argo CD; optional [nginx CI/CD + ALB](cicd/README.md) |

EKS has no free/tiny control-plane instance type to select. `t4g.nano` is the
smallest-memory general-purpose EC2 choice for this CLI-only bastion. A nano or
micro worker is not a practical choice for these Kubernetes system components
and demos. `t3.small` is a small practical **x86** teaching worker, not a claim
that it is the absolute cheapest EC2 offering. One worker has limited memory
and Pod slots; run the lessons sequentially. Use two workers for VPA/Argo CD.

This is deliberately NOT production infrastructure: no worker HA, public
worker IPs, single-replica applications, and a lab-only cluster-admin bastion.
It uses no EKS Auto Mode, NAT gateway, or SSH exposure. The optional
[cicd/](cicd/README.md) demo creates a billable public ALB.

### Cost warning

AWS charges for the EKS control plane even when there are no Pods or workers.
Standard-support EKS is normally **$0.10 per cluster-hour**, plus EC2, EBS,
public IPv4 addresses, traffic, and any burst CPU credit charges. There is no
guarantee of free-tier coverage. Older versions in extended support cost more.
Check [current EKS pricing](https://aws.amazon.com/eks/pricing/) and
[EC2 pricing](https://aws.amazon.com/ec2/pricing/on-demand/) before teaching.
The second worker adds another EC2 instance, disk, and public IPv4 charge.
AZ capacity and quotas are only known when AWS attempts provisioning.
The CI/CD ALB demo adds Application Load Balancer hours, LCU, and a public IPv4.

**Stopping the bastion or scaling Pods to zero does not stop the EKS bill.**
Use `destroy.sh` after class, even if cluster creation only partially succeeded.

### Cost tag `env=test-eks`

Every billable AWS resource this lab creates is tagged **`env=test-eks`**:

| Where | What gets the tag |
|---|---|
| [terraform/](terraform/) provider `default_tags` | VPC, subnets, IGW, EKS cluster, node group, bastion, IAM roles, SGs |
| [terraform/eks.tf](terraform/eks.tf) launch template `tag_specifications` | Worker EC2, root EBS, ENIs |
| [ecr/repositories.yaml](ecr/repositories.yaml) | Private ECR repositories including `nginx-cicd` (still CloudFormation) |
| [ecr/github-oidc.yaml](ecr/github-oidc.yaml) | Optional GitHub OIDC provider and publisher role |
| [cicd/k8s.yaml](cicd/k8s.yaml) Ingress annotation | Internet-facing ALB created by AWS Load Balancer Controller |

Kubernetes Deployments/Services are **not** AWS billable line items and are not tagged.

**Cost Explorer only sees a tag after you activate it as a cost allocation tag.** Do this **before** or at the start of the demo (activation can take up to 24 hours, and usually applies to usage *after* activation):

1. AWS Console → **Billing and Cost Management** → **Cost allocation tags**.
2. Find user-defined tag **`env`** and **Activate** it.
3. After class, **Cost Explorer** → filter **Tag: env** = `test-eks` (same account and region). Also confirm nothing untagged remains from a failed/partial create.

List tagged resources from the CLI:

```bash
aws resourcegroupstaggingapi get-resources --region us-east-2 \
  --tag-filters Key=env,Values=test-eks \
  --query 'ResourceTagMappingList[].ResourceARN' --output table
```

## Prerequisites

Run all `.sh` commands in **Linux, WSL, or Bash**, not directly in PowerShell.
From Windows, use WSL with the tools installed **inside WSL**. Do not mix a
Windows AWS CLI with a Linux Session Manager plugin.

Install current AWS CLI v2, Terraform 1.5+, kubectl 1.35
(or a supported +/-1 minor), Helm 3, the AWS Session Manager plugin, curl,
and Git. VPA installation also needs OpenSSL 1.1.1+ and standard Unix tools.

Authenticate using your normal AWS profile/SSO when you already have one. **Do not put keys in these files.** If `aws sts get-caller-identity` already works, `create.sh` reuses that identity and does not prompt.

If credentials are **not** configured, `create.sh` asks interactively:

1. Access key ID + secret access key (optional session token), saved to the local AWS CLI profile `test-eks` (`~/.aws`), or
2. A named profile / `aws sso login`.

Non-interactive runs (CI, mocked tests) never prompt; they fail with setup instructions instead. `destroy.sh` uses the same credential check. Export `AWS_PROFILE=test-eks` if that is the profile `create.sh` created.

```bash
aws configure sso
aws sso login --profile YOUR-PROFILE
export AWS_PROFILE=YOUR-PROFILE
export AWS_REGION=us-east-2
aws sts get-caller-identity
terraform version
kubectl version --client
helm version
session-manager-plugin --version
```

The provisioning identity needs permissions for EKS, EC2/VPC, IAM role
creation/passing, SSM parameter reads/sessions, EKS access entries, and
CloudFormation for ECR (and optional GitHub OIDC).
Use an instructor-controlled lab account/role with adequate permissions and
quotas, not a student's restricted Kubernetes ServiceAccount.

## Create the Terraform stack

From this directory:

```bash
export CLUSTER_NAME=academy-eks-demo
bash create.sh
```

`create.sh` only checks AWS credentials (prompts if `sts` fails) and runs
`terraform apply` for the VPC, EKS cluster, node group, and SSM bastion.
ECR is optional and separate: `bash ecr/create-repositories.sh`.

On first run it writes `.state/lab.tfvars` (public IPv4 `/32` for the EKS API)
using `https://checkip.amazonaws.com`. You can set it yourself:

```bash
ADMIN_CIDR=203.0.113.10/32 bash create.sh
# Replace the example address with YOUR real public IPv4.
```

Creation typically takes tens of minutes. Tags `env=test-eks` come from
Terraform `default_tags`. See [terraform/README.md](terraform/README.md).
`create.sh` does not install lessons or open SSM. After apply, connect with
`bash connect-bastion.sh`.

Inside the SSM session:

```bash
sudo cloud-init status --wait
sudo su - ec2-user
kubectl get nodes
kubectl get namespaces
```

Cloud-init installs ARM kubectl and Helm with download-checksum checks, and
writes `ec2-user`'s kubeconfig using the instance role. No static AWS keys are
stored. SSM normally opens as `ssm-user`, so switch to `ec2-user` as shown.
If cloud-init reports errors, inspect `/var/log/cloud-init-output.log`; do not
assume the tool installation succeeded.

To reconnect later:

```bash
bash connect-bastion.sh
```

The bastion has a 512 MiB swap file on its encrypted root disk to help tool
installation on 512 MiB RAM. It is intentionally tiny: use it for CLI access, not Docker builds or
running application processes. Infrastructure creation/scaling/deletion commands
run from the instructor's workstation; its EC2 role only has AWS permissions
for SSM and describing this EKS cluster, plus the EKS Kubernetes admin grant.
To use the demo files on the bastion, clone your own lab repository there first.

### kubectl versus Terraform versus etcdctl

- **kubectl**: all normal EKS Kubernetes work (`get`, `apply`, `logs`, `top`, etc.).
- **Terraform**: creates/deletes the VPC, EKS cluster, node group, and bastion; `scale-workers.sh` runs `terraform apply`.
- **etcdctl**: not used anywhere in this lab. EKS manages etcd for you.

Configure local kubeconfig after apply:

```bash
aws eks update-kubeconfig --region us-east-2 \
  --name academy-eks-demo --alias academy-eks-demo
kubectl config current-context
kubectl get nodes -o wide
```
## CI/CD: nginx version 1 then 2 via ALB Ingress

From the instructor workstation (Docker + Helm + kubectl), after kubeconfig:

```bash
bash cicd/pipeline.sh 1
# prints: app version 1
bash cicd/pipeline.sh 2
# prints: app version 2
```

This builds nginx, pushes `nginx-cicd:vN` to ECR, applies Deployment + Service +
Ingress, and waits for the AWS ALB hostname. See [cicd/README.md](cicd/README.md).
Re-run `bash create.sh` once so Terraform has the ALB controller IAM role.
Delete `kubectl delete namespace cicd-demo` before `destroy.sh` so the ALB does
not block VPC deletion.


If your workstation public IP changes, update `.state/lab.tfvars` `admin_cidr`
and re-apply so Terraform stays the source of truth:

```bash
IP="$(curl -fsS https://checkip.amazonaws.com)"
# edit .state/lab.tfvars admin_cidr = "YOUR_IP/32"
terraform -chdir=terraform apply -var-file=../.state/lab.tfvars
```

## HPA: add/remove Pods in response to CPU use

HPA, VPA, and Argo CD all run on the **AWS EKS** cluster from `create.sh`.
`kubectl` must point at that cluster (`check_context` enforces it). See
[hpa/README.md](hpa/README.md). Scale-up and scale-down are both in
[hpa/demo.yaml](hpa/demo.yaml).

```bash
bash hpa/install-metrics.sh
kubectl apply -f hpa/demo.yaml
kubectl -n hpa-demo rollout status deployment/cpu-web --timeout=180s
kubectl apply -f hpa/load.yaml
kubectl -n hpa-demo get hpa cpu-web -w
# In other terminals:
kubectl -n hpa-demo top pods
kubectl -n hpa-demo get pods -w
kubectl -n hpa-demo describe hpa cpu-web
```

The PHP endpoint performs CPU work. The bounded load Job drives requests for
10 minutes or until you delete it. HPA targets 50% of the **50m CPU request**,
not the 200m CPU limit, scaling from one to at most three replicas. The HPA
formula uses average CPU across eligible Pods; allow a few metrics cycles.
`<unknown>` can appear initially. Inspect HPA conditions and Metrics Server
logs if it persists. Do not blindly disable kubelet TLS verification.

```bash
kubectl -n hpa-demo delete job cpu-load --ignore-not-found
kubectl -n hpa-demo get hpa,pods -w
# Observe gradual scale-down after the 60-second stabilization window.
kubectl delete namespace hpa-demo
```

Applying `hpa/demo.yaml` again resets the Deployment's declared replicas to one
until HPA reconciles. Do not repeatedly apply during the scaling demonstration.
The load/inspection commands are also at the bottom of the manifests.

HPA does not add EC2 workers. A Pending Pod with insufficient resources is not
an HPA failure; inspect `kubectl describe pod` and scale the worker group manually.
There is deliberately no Cluster Autoscaler/Karpenter in this cost-bounded lab.

## VPA: change a Pod's CPU/memory requests

Your requested "virtual scaling" is implemented as **Vertical Pod Autoscaler**.
It targets a different Deployment from HPA to avoid conflicting CPU controllers.

```bash
bash scale-workers.sh 2
bash hpa/install-vpa.sh
kubectl apply -f hpa/vpa-demo.yaml
kubectl -n vpa-demo rollout status deployment/vertical-demo
bash hpa/vpa-load.sh
# In another terminal, wait several minutes for recommendations:
kubectl -n vpa-demo describe vpa vertical-demo
kubectl -n vpa-demo top pods
```

Start in `Off` mode (recommendations only). Then:

```bash
bash hpa/vpa-mode.sh initial
kubectl -n vpa-demo get pods \
  -o custom-columns=NAME:.metadata.name,REQUESTS:.spec.containers[0].resources.requests
bash hpa/vpa-mode.sh off
```

`Initial` applies recommendations when new Pods are created; the script explicitly
restarts this demo Deployment. It is not in-place resizing or continuous
eviction-based automatic resizing. `RequestsOnly` preserves the fixed limits,
and recommendations are bounded below those limits for this tiny lab.
Returning to `Off` does not restore existing requests. The load script stops
after five minutes and clears its marker on exit; if a connection is forcibly
lost, clear it with:

```bash
kubectl -n vpa-demo exec deployment/vertical-demo -- rm -f /tmp/load
kubectl delete namespace vpa-demo
```

VPA is pinned to `1.6.0` (compatible with Kubernetes 1.35). The installer uses
the upstream installation scripts, including admission-webhook certificates,
and refuses to overwrite an existing VPA CRD. It does not merely create a VPA
resource without its controllers. To reclaim resources before the Argo lesson,
remove this dedicated lab's VPA system components with the matching upstream
script (only after deleting `vpa-demo`):

```bash
git clone --depth 1 --branch vertical-pod-autoscaler-1.6.0 \
  https://github.com/kubernetes/autoscaler.git /tmp/academy-vpa-remove
cd /tmp/academy-vpa-remove/vertical-pod-autoscaler
bash hack/vpa-down.sh
# Return to your EKS directory before running the next commands.
```

Do not run that teardown on a shared cluster or with other VPA workloads.

## Helm and Argo CD

Follow [argo/README.md](argo/README.md) for Helm install/upgrade/rollback, local
browser access, Argo CD setup, repository configuration, GitOps updates, and
self-healing. Use two workers and remove the earlier lesson namespaces first.
The chart is usable locally immediately; Argo CD requires your own reachable
Git repository. Both placeholder URLs in the Application must be edited.

## Destroy everything this AWS lab creates

Run from the instructor workstation, **not inside the bastion you are deleting**.
Use the same profile, region, and cluster name used for creation:

```bash
export AWS_PROFILE=YOUR-PROFILE
export AWS_REGION=us-east-2
export CLUSTER_NAME=academy-eks-demo
bash destroy.sh
```

`destroy.sh` checks AWS credentials, then `terraform destroy` (bastion, node
group, EKS, VPC, IAM). That disrupts all workloads in this dedicated lab
cluster. It does **not** delete ECR or the GitHub OIDC CloudFormation stacks;
remove those with `ecr/create-repositories.sh` inverted via
`aws cloudformation delete-stack` if you created them.

If you ran the nginx ALB demo, delete it first so the load balancer does not
block VPC deletion:

```bash
kubectl delete namespace cicd-demo --ignore-not-found
```

Terraform does not create that ALB; Ingress does. The stack also has no
persistent application volumes. If you add other dependent resources yourself,
remove them first: retained volumes or external ENIs can block cleanup.
The script fails explicitly on AWS errors; inspect and retry rather than
assuming a failed deletion stopped billing.

Verify in the AWS console (EKS, CloudFormation, EC2, EBS, public IPs, and VPC):

```bash
aws eks list-clusters --region us-east-2
aws cloudformation list-stacks --region us-east-2 \
  --stack-status-filter CREATE_COMPLETE DELETE_FAILED ROLLBACK_COMPLETE
aws ec2 describe-instances --region us-east-2 \
  --filters "Name=tag:env,Values=test-eks" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key==`env`].Value|[0]]' --output table
```

After teardown, Cost Explorer still shows historical charges for `env=test-eks`.
Untagged leftovers (failed stacks, orphaned volumes) will **not** appear in that
filter — inspect CloudFormation/EC2 directly.

Missing stack errors can occur after partial/manual cleanup; do not hide unrelated
permission/network failures. Resolve the specific reported error and retry.
Local kubeconfig context entries and the ignored `.state/` Terraform files are
not AWS billable resources; they are not automatically deleted.

## Local validation without provisioning

From PowerShell in this directory:

```powershell
.\validate.ps1
```

Requires WSL Bash, Python with PyYAML, Helm, and Terraform on the local PATH.
This checks Bash syntax, all YAML, `terraform fmt`/`validate`, chart rendering,
invalid Helm values, workload selectors, autoscaling bounds, ALB Ingress
manifests, and ECR CloudFormation tags. It also executes mocked lifecycle
scenarios: credential gate, terraform apply/destroy, failure propagation,
SSM timeout, cluster context safety, VPA mode changes, and nginx CI/CD
v1 then v2. It does **not** call AWS or create a cluster. On Linux you can
run those execution tests directly:

```bash
bash tests/lifecycle.sh
```

Static checks cannot prove AWS quotas, IAM permissions, regional/AZ capacity,
container pull availability, measured HPA behavior, webhook admission, or SSM
connectivity. A real provision/load test is needed to verify those. No live AWS
resources were provisioned as part of preparing this lab.
