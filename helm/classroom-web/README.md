# Standalone classroom web chart

This self-contained chart needs only Helm 3+ and a Kubernetes cluster. It has no
Argo CD, EKS, ingress controller, storage, or other chart dependencies. It creates
a Deployment, ConfigMap, and Service in the release namespace.

Run commands from this chart directory. On Windows, use PowerShell with a
MicroK8s kubeconfig. On the MicroK8s host, use `microk8s helm3` instead of `helm`
(enable it with `microk8s enable helm3`), and `microk8s kubectl` instead of
`kubectl` if standalone clients are not configured.

## Install independently

```powershell
kubectl config use-context microk8s
helm lint . --strict
helm template classroom . --namespace helm-demo
helm upgrade --install classroom . --namespace helm-demo --create-namespace --wait --timeout 5m
kubectl -n helm-demo get deployment,pods,service,configmap
kubectl get nodes -o wide
```

Open `http://NODE_IP:30096`, replacing `NODE_IP` with a reachable MicroK8s node
address. Allow TCP 30096 only from trusted lab clients in the host firewall.
NodePort is plain HTTP and may be exposed on multiple nodes; do not put secrets
in the page. A remote node is not your workstation's `localhost`.

The default replica count is 1, suitable for a single-node lab. Kubernetes still
needs enough available CPU and memory for the application and any other labs.

## Update and roll back

```powershell
helm upgrade classroom . -n helm-demo --set-string message="Updated through Helm!" --wait --timeout 5m
helm history classroom -n helm-demo
helm rollback classroom 1 -n helm-demo --wait --timeout 5m
```

Changing the message changes the Pod-template checksum and triggers a rollout;
the subPath ConfigMap mount is refreshed when Pods are replaced.

## Values

| Value | Default | Purpose |
|---|---|---|
| `replicaCount` | `1` | Number of replicas, from 1 to 3 |
| `message` | `Hello from the classroom Helm chart!` | Page content |
| `image.repository` | `nginx` | Container repository |
| `image.tag` | `1.28-alpine` | Container tag |
| `image.pullPolicy` | `IfNotPresent` | Image pull policy |
| `service.type` | `NodePort` | `NodePort` or `ClusterIP` |
| `service.port` | `80` | Service HTTP port |
| `service.nodePort` | `30096` | NodePort in the standard 30000-32767 range |
| `resources` | See [values.yaml](values.yaml) | CPU and memory requests/limits |

NodePorts are cluster-wide, not namespace-scoped. Give every additional release
a different `service.nodePort`; the Argo CD example uses 30097. If your cluster
uses a custom NodePort range, update the value and JSON schema accordingly.

To keep traffic local to the cluster and use port-forward instead:

```powershell
helm upgrade --install classroom . -n helm-demo --create-namespace --set service.type=ClusterIP --wait --timeout 5m
kubectl -n helm-demo port-forward svc/classroom 8081:80
```

Leave that terminal running and open `http://localhost:8081`.

## Package and install elsewhere

```powershell
helm package .
helm upgrade --install classroom .\classroom-web-0.2.0.tgz --namespace helm-demo --create-namespace --wait --timeout 5m
```

The archive is independently installable; it does not need the surrounding
workspace. For Argo CD management of this same chart, see
[the GitOps lesson](../../argo/README.md). Never let Helm and Argo CD manage the
same resources; use separate release names and namespaces.

## Cleanup

```powershell
helm uninstall classroom -n helm-demo --wait
```

This leaves the namespace intact. Delete `helm-demo` only if you created it for
this lesson and it contains nothing else you need.
