$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Temp = Join-Path ([System.IO.Path]::GetTempPath()) ("academy-eks-validation-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $Temp | Out-Null
try {
    foreach ($Tool in @('bash', 'python', 'helm', 'terraform')) {
        Get-Command $Tool -ErrorAction Stop | Out-Null
    }
    & helm lint (Join-Path $Root 'argo\chart') --strict
    if ($LASTEXITCODE -ne 0) { throw 'Helm lint failed' }
    $Default = & helm template classroom (Join-Path $Root 'argo\chart') --namespace helm-demo
    if ($LASTEXITCODE -ne 0) { throw 'Default Helm rendering failed' }
    $Override = & helm template classroom (Join-Path $Root 'argo\chart') --namespace helm-demo --set replicaCount=2 --set-string 'message=Changed in validation'
    if ($LASTEXITCODE -ne 0) { throw 'Override Helm rendering failed' }
    $ErrorActionPreference = 'Continue'
    & helm template classroom (Join-Path $Root 'argo\chart') --set replicaCount=0 2>$null | Out-Null
    $SchemaRejected = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($SchemaRejected -eq 0) { throw 'Chart incorrectly accepted replicaCount=0' }
    $TfDir = Join-Path $Root 'terraform'
    & terraform "-chdir=$TfDir" fmt -check
    if ($LASTEXITCODE -ne 0) { throw 'Terraform files are not formatted (terraform fmt -check)' }
    & terraform "-chdir=$TfDir" init -backend=false -input=false
    if ($LASTEXITCODE -ne 0) { throw 'terraform init -backend=false failed' }
    & terraform "-chdir=$TfDir" validate
    if ($LASTEXITCODE -ne 0) { throw 'terraform validate failed' }
    $Encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Join-Path $Temp 'default.yaml'), ($Default -join "`n"), $Encoding)
    [System.IO.File]::WriteAllText((Join-Path $Temp 'override.yaml'), ($Override -join "`n"), $Encoding)
    @'
import hashlib
import subprocess
import sys
from pathlib import Path
import yaml

root, temp = map(Path, sys.argv[1:])
for script in root.rglob("*.sh"):
    data = script.read_bytes()
    assert b"\r" not in data, f"Use LF, not Windows CRLF: {script}"
    subprocess.run(["bash", "-n"], input=data, check=True)

class CfnLoader(yaml.SafeLoader):
    pass

def intrinsic(loader, tag, node):
    if isinstance(node, yaml.ScalarNode):
        value = loader.construct_scalar(node)
    elif isinstance(node, yaml.SequenceNode):
        value = loader.construct_sequence(node)
    else:
        value = loader.construct_mapping(node)
    return {tag: value}

CfnLoader.add_multi_constructor("!", intrinsic)
count = 0
for path in root.rglob("*.yaml"):
    if "templates" in path.parts or ".state" in path.parts:
        continue
    docs = list(yaml.load_all(path.read_text(encoding="utf-8"), Loader=CfnLoader))
    assert all(isinstance(doc, dict) for doc in docs), path
    count += len(docs)

assert not (root / "cluster.yaml").exists(), "eksctl cluster.yaml must not be used"
assert not (root / "bastion.yaml").exists(), "CloudFormation bastion.yaml must not be used"

def documents(relative):
    return list(yaml.safe_load_all((root / relative).read_text()))

def one(docs, kind):
    return next(d for d in docs if d["kind"] == kind)

hpa = documents("hpa/demo.yaml")
deployment, service, scaler = (one(hpa, kind) for kind in ("Deployment", "Service", "HorizontalPodAutoscaler"))
pod = deployment["spec"]["template"]
assert service["spec"]["selector"] == pod["metadata"]["labels"] == deployment["spec"]["selector"]["matchLabels"]
assert scaler["spec"]["scaleTargetRef"]["name"] == deployment["metadata"]["name"]
assert scaler["spec"]["maxReplicas"] == 3
assert scaler["spec"]["metrics"][0]["resource"]["target"]["averageUtilization"] == 50
assert "scaleUp" in scaler["spec"]["behavior"]
assert "scaleDown" in scaler["spec"]["behavior"]
assert scaler["spec"]["behavior"]["scaleUp"]["stabilizationWindowSeconds"] == 0
assert pod["spec"]["containers"][0]["resources"]["requests"]["cpu"] == "50m"
assert all(d["metadata"].get("namespace") == "hpa-demo" for d in hpa if d["kind"] != "Namespace")
load = documents("hpa/load.yaml")[0]
assert load["spec"]["activeDeadlineSeconds"] == 600
assert load["metadata"]["namespace"] == "hpa-demo"
vpa_docs = documents("hpa/vpa-demo.yaml")
vpa = one(vpa_docs, "VerticalPodAutoscaler")
assert vpa["spec"]["targetRef"]["name"] == one(vpa_docs, "Deployment")["metadata"]["name"]
assert vpa["spec"]["updatePolicy"]["updateMode"] == "Off"
policy = vpa["spec"]["resourcePolicy"]["containerPolicies"][0]
assert policy["controlledValues"] == "RequestsOnly"
assert policy["maxAllowed"] == {"cpu": "150m", "memory": "128Mi"}

for filename, replicas, message in (
    ("default.yaml", 1, "Hello from the classroom Helm chart!"),
    ("override.yaml", 2, "Changed in validation"),
):
    rendered = list(yaml.safe_load_all((temp / filename).read_text()))
    dep, svc, cm = (one(rendered, kind) for kind in ("Deployment", "Service", "ConfigMap"))
    assert dep["spec"]["replicas"] == replicas
    assert svc["spec"]["selector"] == dep["spec"]["template"]["metadata"]["labels"]
    assert all(d["metadata"]["namespace"] == "helm-demo" for d in rendered)
    assert cm["data"]["index.html"].strip() == message
    assert dep["spec"]["template"]["metadata"]["annotations"]["checksum/page"] == hashlib.sha256(message.encode()).hexdigest()

cicd = documents("cicd/k8s.yaml")
cicd_dep, cicd_svc, cicd_ing = (one(cicd, kind) for kind in ("Deployment", "Service", "Ingress"))
assert cicd_svc["spec"]["selector"] == cicd_dep["spec"]["template"]["metadata"]["labels"] == cicd_dep["spec"]["selector"]["matchLabels"]
assert cicd_ing["spec"]["ingressClassName"] == "alb"
assert cicd_ing["metadata"]["annotations"]["alb.ingress.kubernetes.io/scheme"] == "internet-facing"
assert cicd_ing["spec"]["rules"][0]["http"]["paths"][0]["backend"]["service"]["name"] == cicd_svc["metadata"]["name"]
assert cicd_dep["spec"]["template"]["spec"]["containers"][0]["image"] == "__IMAGE__"
pipeline_sh = (root / "cicd/pipeline.sh").read_text(encoding="utf-8")
assert "eksctl" not in pipeline_sh
assert "linux/amd64" in pipeline_sh
assert "aws-load-balancer-controller" in pipeline_sh
assert "APP_VERSION" in pipeline_sh

project, app = documents("argo/application.yaml")
assert app["spec"]["project"] == project["metadata"]["name"]
assert app["spec"]["source"]["repoURL"] in project["spec"]["sourceRepos"]
assert app["spec"]["destination"] in project["spec"]["destinations"]
assert (root / app["spec"]["source"]["path"] / "Chart.yaml").is_file()
assert project["spec"]["clusterResourceWhitelist"] == []

def has_cost_tag(props):
    tags = props.get("Tags") or []
    return any(isinstance(t, dict) and t.get("Key") == "env" and t.get("Value") == "test-eks" for t in tags)

ecr = yaml.load((root / "ecr/repositories.yaml").read_text(), Loader=CfnLoader)
assert all(has_cost_tag(r["Properties"]) for r in ecr["Resources"].values())
oidc = yaml.load((root / "ecr/github-oidc.yaml").read_text(), Loader=CfnLoader)
assert has_cost_tag(oidc["Resources"]["PublisherRole"]["Properties"])
assert has_cost_tag(oidc["Resources"]["GitHubProvider"]["Properties"])
assert any("nginx-cicd" in str(r) for r in oidc["Resources"]["PublisherRole"]["Properties"]["Policies"][0]["PolicyDocument"]["Statement"])

commands = []
for relative in ("hpa/demo.yaml", "hpa/load.yaml", "hpa/vpa-demo.yaml"):
    for doc in documents(relative):
        if doc["kind"] == "Deployment":
            containers = doc["spec"]["template"]["spec"]["containers"]
        elif doc["kind"] == "Job":
            containers = doc["spec"]["template"]["spec"]["containers"]
        else:
            continue
        commands.extend(c["command"][2] for c in containers if "command" in c)
for command in commands:
    subprocess.run(["bash", "-n"], input=command.encode("utf-8"), check=True)
user_data = (root / "terraform" / "user_data.sh.tpl").read_bytes()
subprocess.run(["bash", "-n"], input=user_data, check=True)
tf_dir = root / "terraform"
assert (tf_dir / "versions.tf").is_file()
assert (tf_dir / "eks.tf").is_file()
assert (tf_dir / "bastion.tf").is_file()
assert (tf_dir / "vpc.tf").is_file()
tf_text = "\n".join(p.read_text(encoding="utf-8") for p in tf_dir.glob("*.tf"))
assert "default_tags" in tf_text
assert "test-eks" in tf_text
assert "t3.small" in tf_text
assert "t4g.nano" in tf_text
assert "aws_nat_gateway" not in tf_text
assert "aws_eks_cluster" in tf_text
assert "AmazonEKSClusterPolicy" in tf_text
assert "AmazonEKSVPCResourceController" in tf_text
assert "AmazonSSMManagedInstanceCore" in tf_text
assert "aws_iam_openid_connect_provider" in tf_text
assert "alb_controller" in tf_text
assert (tf_dir / "aws-load-balancer-controller-iam-policy.json").is_file()
assert "public_access_cidrs" in tf_text
assert "map_public_ip_on_launch" in tf_text
create_sh = (root / "create.sh").read_text(encoding="utf-8")
destroy_sh = (root / "destroy.sh").read_text(encoding="utf-8")
assert "eksctl" not in create_sh and "eksctl" not in destroy_sh
assert "bastion.yaml" not in create_sh and "cluster.yaml" not in create_sh
assert "ensure_aws_credentials" in create_sh and "tf apply" in create_sh
assert "create-repositories" not in create_sh
assert "connect-bastion" not in create_sh
assert "ensure_aws_credentials" in destroy_sh and "tf destroy" in destroy_sh
assert "delete-stack" not in destroy_sh
print(f"PASS: {count} YAML documents, Terraform module, HPA/VPA wiring, Helm overrides/checksums, ECR tags, and embedded shell syntax.")
'@ | & python - $Root $Temp
    if ($LASTEXITCODE -ne 0) { throw 'Manifest validation failed' }
    $LinuxRoot = (wsl wslpath $Root).Trim()
    if (-not $LinuxRoot) { throw 'wslpath failed; install WSL to run tests/lifecycle.sh' }
    wsl -e bash -lc "bash '$LinuxRoot/tests/lifecycle.sh'"
    if ($LASTEXITCODE -ne 0) { throw 'Mocked lifecycle tests failed (validate.ps1 expects WSL Bash)' }
    & python (Join-Path $Root 'ecr\test-images.py')
    if ($LASTEXITCODE -ne 0) { throw 'ECR image and GitOps pipeline checks failed' }
    Write-Host 'PASS: all Bash files parsed; Helm lint passed and invalid replicaCount was rejected. No AWS calls made.'
}
finally {
    Remove-Item -LiteralPath $Temp -Recurse -Force
}
