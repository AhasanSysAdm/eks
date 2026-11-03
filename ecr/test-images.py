"""Offline tests for ECR references and GitOps pipeline wiring."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import yaml


root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="academy-ecr-test-") as directory:
    target = Path(directory)
    for folder in ("ecr", "hpa", "argo/chart"):
        (target / folder).mkdir(parents=True, exist_ok=True)
    for relative in (
        "ecr/update-images.py", "hpa/demo.yaml", "hpa/load.yaml",
        "hpa/vpa-demo.yaml", "argo/chart/values.yaml",
    ):
        shutil.copyfile(root / relative, target / relative)
    command = [
        sys.executable, str(target / "ecr/update-images.py"),
        "--registry", "123456789012.dkr.ecr.us-east-2.amazonaws.com",
        "--cluster", "academy-eks-demo", "--tag", "test-123",
    ]
    subprocess.run(command, check=True)
    for relative, image in (
        ("hpa/demo.yaml", "php"), ("hpa/load.yaml", "busybox"),
        ("hpa/vpa-demo.yaml", "busybox"),
    ):
        docs = list(yaml.safe_load_all((target / relative).read_text()))
        workload = next(d for d in docs if d["kind"] in ("Deployment", "Job"))
        actual = workload["spec"]["template"]["spec"]["containers"][0]["image"]
        assert actual == f"123456789012.dkr.ecr.us-east-2.amazonaws.com/academy-eks-demo/{image}:test-123"
    values = yaml.safe_load((target / "argo/chart/values.yaml").read_text())
    assert values["image"]["repository"].endswith("/academy-eks-demo/web")
    assert values["image"]["tag"] == "test-123"
    before = (target / "argo/chart/values.yaml").read_bytes()
    result = subprocess.run(command[:-1] + ["invalid tag"], capture_output=True)
    assert result.returncode != 0
    assert (target / "argo/chart/values.yaml").read_bytes() == before
    subprocess.run(
        ["helm", "lint", str(root / "argo/chart"), "--strict",
         "-f", str(target / "argo/chart/values.yaml")], check=True,
    )
workflow = yaml.safe_load((root / ".github/workflows/publish-gitops.yaml").read_text())
assert workflow["permissions"]["id-token"] == "write"
steps = workflow["jobs"]["publish"]["steps"]
assert any(s.get("uses", "").startswith("aws-actions/configure-aws-credentials@") for s in steps)
assert "kubectl" not in "\n".join(s.get("run", "") for s in steps)
assert any("ecr/build-push.sh" in s.get("run", "") for s in steps)
assert any("git push origin HEAD:main" in s.get("run", "") for s in steps)
nginx = yaml.safe_load((root / ".github/workflows/publish-nginx-cicd.yaml").read_text())
assert nginx["permissions"]["id-token"] == "write"
nginx_run = "\n".join(s.get("run", "") for s in nginx["jobs"]["publish"]["steps"])
assert "kubectl" not in nginx_run
assert "cicd/Dockerfile" in nginx_run
assert "linux/amd64" in nginx_run
repos = (root / "ecr/repositories.yaml").read_text(encoding="utf-8")
assert "nginx-cicd" in repos
oidc = (root / "ecr/github-oidc.yaml").read_text(encoding="utf-8")
assert "nginx-cicd" in oidc
print("PASS: ECR references for all apps, invalid tag rejection, ECR Helm values, OIDC and GitOps pipeline wiring.")
