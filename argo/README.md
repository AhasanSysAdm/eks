# Helm and Argo CD classroom demo

Run commands in Bash from the **EKS directory**, against the **AWS EKS** lab
cluster created by `create.sh`. This is not MicroK8s. Use a local terminal for
browser port-forwarding, not a remote SSM session.
Use the labs sequentially: delete `hpa-demo` and `vpa-demo` if they exist.
Argo CD is self-hosted here, not the separately billed EKS Argo CD capability.
For private ECR images and automated build/publish/GitOps promotion, follow
[the ECR pipeline lesson](../ecr/README.md). Run its image-reference updater
before the Helm lesson to use ECR instead of the default upstream image.

## 1. Demonstrate Helm without Argo CD

```bash
helm lint argo/chart --strict
helm template classroom argo/chart --namespace helm-demo
helm upgrade --install classroom argo/chart \
  --namespace helm-demo --create-namespace --wait --timeout 5m
helm list -n helm-demo
helm get values classroom -n helm-demo
kubectl -n helm-demo get deployment,pods,service,configmap
kubectl -n helm-demo port-forward svc/classroom 8081:80
```

In another terminal:

```bash
curl http://localhost:8081
```

Leave port-forward running while testing. To demonstrate a values override,
stop the port-forward, then:

```bash
helm upgrade classroom argo/chart -n helm-demo \
  --set-string message="Updated through Helm!" --wait --timeout 5m
helm history classroom -n helm-demo
kubectl -n helm-demo port-forward svc/classroom 8081:80
# In another terminal: curl http://localhost:8081
```

The page checksum triggers a Deployment rollout when the message changes.
Stop port-forward, roll back, and start port-forward again to inspect the old page:

```bash
helm rollback classroom 1 -n helm-demo --wait --timeout 5m
helm uninstall classroom -n helm-demo
kubectl delete namespace helm-demo
```

## 2. Install Argo CD

```bash
bash scale-workers.sh 2
bash argo/install-argocd.sh
kubectl -n argocd get pods
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 --decode; echo
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Open **https://localhost:8080**, accept the lab's self-signed certificate, and
log in as `admin` with the printed password. Do not share that password or commit
it. The Service remains ClusterIP; no paid AWS load balancer is created.
The installer pins Argo CD `v3.5.6` and uses server-side apply for large CRDs.
This is the small, non-HA installation, not production sizing.

## 3. Put the chart in Git

Argo CD cannot read your workstation's local chart folder. Publish the contents
of **EKS as the repository root** to a repository you own, for example
`https://github.com/YOUR-USER/eks-classroom.git`, on branch `main`.
For this lesson use a public repository containing ONLY these lab files.
Do not upload credentials, kubeconfig files, generated state, or unrelated code.
If you instead put the entire Academy folder in Git, change the Application's
`source.path` to `EKS/argo/chart`.

Edit **both** repository URLs in `argo/application.yaml` to your real URL.
Also adjust `targetRevision` if your branch is not `main`. Then:

```bash
kubectl apply -f argo/application.yaml
kubectl -n argocd get applications
kubectl -n argocd get application classroom -w
# Stop the watch after STATUS=Synced and HEALTH=Healthy.
kubectl -n gitops-demo get deployment,pods,service
kubectl -n gitops-demo port-forward svc/gitops-demo 8082:80
# In another terminal:
curl http://localhost:8082
```

The AppProject permits only this repository and ConfigMaps, Services, and
Deployments in `gitops-demo`. The installer creates the namespace first.
No cluster-scoped resources can be deployed through this project.

## 4. Demonstrate GitOps and self-healing

Change `message` in `argo/chart/values.yaml`, commit, and push to your repository.
Argo CD periodically polls Git (allow several minutes), or refresh immediately:

```bash
kubectl -n argocd annotate application classroom argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd get application classroom -w
```

After sync, restart the port-forward if its Pod was replaced and refresh the page.
Show drift correction:

```bash
kubectl -n gitops-demo scale deployment gitops-demo --replicas=2
kubectl -n gitops-demo get deployment gitops-demo -w
```

Argo CD should restore the replica count from Git. It uses Helm to **render**
manifests, not to create a Helm release; `helm list` will not show the
Argo-managed application. Do not run Helm upgrades against Argo-owned resources.

## Inspect / clean up

```bash
kubectl -n argocd describe application classroom
kubectl -n argocd logs statefulset/argocd-application-controller --tail=50
kubectl -n gitops-demo get events --sort-by=.lastTimestamp
```

This Application deliberately has no cascade-deletion finalizer. To remove the
lesson without GitOps recreating it, delete the Application first, then its
namespace:

```bash
kubectl -n argocd delete application classroom
kubectl -n argocd delete appproject classroom
kubectl delete namespace gitops-demo
kubectl delete namespace argocd
```

Argo CD CRDs/cluster RBAC remain until cluster deletion. Do not remove shared
CRDs from a reused cluster. Finally run the root cleanup script to stop AWS bills.
