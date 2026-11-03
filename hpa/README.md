# HPA and VPA on AWS EKS

These manifests run on the **AWS EKS** cluster from `create.sh`. They use
public images (`php:8.3-apache`, `busybox:1.36`) so the lesson still works
before ECR images are published. `kubectl` must point at the lab cluster
(`check_context` in the install scripts).

Do **not** run HPA and VPA at the same time on one `t3.small`. Delete
`hpa-demo` before VPA. Use `bash scale-workers.sh 2` for VPA/Argo.

## HPA (horizontal: add/remove Pods)

[demo.yaml](demo.yaml) is the HPA lab (`cpu-web` Deployment + `HorizontalPodAutoscaler`).
Scale-**up** and scale-**down** are both declared under `spec.behavior`.

- **Scale-up:** CPU above 50% of the **50m request** (~25m). Window `0s`; can
  add up to 2 Pods or 100% per 15s, capped at `maxReplicas: 3`.
- **Scale-down:** 60s stabilization, then 1 Pod every 30s, down to 1 replica.
- **Load:** [load.yaml](load.yaml) hits `http://cpu-web.hpa-demo.svc.cluster.local/`
  for 10 minutes.

```bash
cd /path/to/EKS
bash hpa/install-metrics.sh
kubectl apply -f hpa/demo.yaml
kubectl -n hpa-demo rollout status deployment/cpu-web --timeout=180s
kubectl apply -f hpa/load.yaml
kubectl -n hpa-demo get hpa cpu-web -w
```

Other terminals:

```bash
kubectl -n hpa-demo top pods
kubectl -n hpa-demo get pods -w
kubectl -n hpa-demo describe hpa cpu-web
```

Stop load and watch scale-down:

```bash
kubectl -n hpa-demo delete job cpu-load --ignore-not-found
kubectl delete namespace hpa-demo
```

`<unknown>` on the HPA usually means Metrics Server is not ready yet. Wait for
`kubectl top nodes` to work. Do not disable kubelet TLS verification.

HPA does not add EC2 workers. Scale workers with Terraform via
`bash scale-workers.sh 2`.

## VPA (vertical: change CPU/memory requests)

[vpa-demo.yaml](vpa-demo.yaml) is a different Deployment so HPA and VPA do not
fight over the same CPU target.

```bash
bash scale-workers.sh 2
kubectl delete namespace hpa-demo --ignore-not-found
bash hpa/install-metrics.sh
bash hpa/install-vpa.sh
kubectl apply -f hpa/vpa-demo.yaml
kubectl -n vpa-demo rollout status deployment/vertical-demo
bash hpa/vpa-load.sh
# elsewhere:
kubectl -n vpa-demo describe vpa vertical-demo
bash hpa/vpa-mode.sh initial
bash hpa/vpa-mode.sh off
kubectl delete namespace vpa-demo
```

VPA controllers stay in `kube-system` until you remove them with the upstream
`hack/vpa-down.sh` from `vertical-pod-autoscaler-1.6.0`. See the parent
[README.md](../README.md).
