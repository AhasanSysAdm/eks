#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
cleanup() {
  local status=$?
  if (( status != 0 )); then
    echo "Lifecycle test failed. Last script output and mock calls:" >&2
    if [[ -f "$WORK/output" ]]; then cat "$WORK/output" >&2; fi
    if [[ -f "$WORK/calls.log" ]]; then cat "$WORK/calls.log" >&2; fi
  fi
  rm -rf -- "$WORK"
  exit "$status"
}
trap cleanup EXIT
mkdir -p "$WORK/hpa" "$WORK/argo" "$WORK/ecr"
cp -- "$ROOT/ecr/create-repositories.sh" "$ROOT/ecr/repositories.yaml" "$WORK/ecr/"
cp -- "$ROOT/common.sh" "$ROOT/create.sh" "$ROOT/destroy.sh" \
  "$ROOT/connect-bastion.sh" "$WORK/"
cp -R -- "$ROOT/terraform" "$WORK/terraform"
cp -R -- "$ROOT/cicd" "$WORK/cicd"
cp -- "$ROOT/hpa/install-metrics.sh" "$ROOT/hpa/vpa-mode.sh" "$WORK/hpa/"
export CALL_LOG="$WORK/calls.log"
export CLUSTER_NAME=academy-eks-demo AWS_REGION=us-east-2
unset CONFIRM_CREATE CONFIRM_DELETE ADMIN_CIDR

# These exported functions replace every cloud CLI used by the child scripts.
aws() {
  printf 'aws %s\n' "$*" >> "$CALL_LOG"
  case "$*" in
    'sts get-caller-identity'*)
      if [[ "${MOCK_NO_CREDS:-0}" == 1 ]]; then return 1; fi
      if [[ "$*" == *Account* ]]; then echo 000000000000; else printf '{"Account":"000000000000"}\n'; fi ;;
    'ec2 describe-instance-type-offerings '*) echo 1 ;;
    'eks describe-cluster '*)
      case "$*" in
        *resourcesVpcConfig.vpcId*) echo vpc-mock ;;
        *clusterSecurityGroupId*) echo sg-cluster-mock ;;
        *cluster.endpoint*) echo https://mock.eks.example ;;
        *cluster.arn*) echo arn:aws:eks:us-east-2:000000000000:cluster/academy-eks-demo ;;
        *) echo "Unexpected cluster query" >&2; return 90 ;;
      esac ;;
    'eks tag-resource '*|'ec2 create-tags '*|'ecr tag-resource '*) : ;;
    'ec2 describe-subnets '*) echo subnet-mock ;;
    'ec2 describe-internet-gateways '*) echo igw-mock ;;
    'ec2 describe-route-tables '*) echo rtb-mock ;;
    'ec2 describe-security-groups '*) echo sg-mock ;;
    'ec2 describe-network-interfaces '*) echo eni-mock ;;
    'ec2 describe-instances '*) echo i-mock ;;
    'ecr describe-repositories '*) echo arn:aws:ecr:us-east-2:000000000000:repository/academy-eks-demo/web ;;
    'ecr get-login-password'*) echo mock-ecr-password ;;
    'ecr create-repository '*) : ;;
    'ecr describe-images '*) return 1 ;;
    'ssm get-parameter '*) echo ami-mock ;;
    'cloudformation deploy '*) : ;;
    'cloudformation describe-stacks '*)
      case "$*" in
        *RoleArn*) echo arn:aws:iam::000000000000:role/mock-bastion ;;
        *InstanceId*) echo i-mock ;;
        *) return 91 ;;
      esac ;;
    'eks update-kubeconfig '*|'eks create-access-entry '*|'eks associate-access-policy '*) : ;;
    'ssm describe-instance-information '*)
      if [[ "${MOCK_SSM_OFFLINE:-0}" == 1 ]]; then echo None; else echo Online; fi ;;
    'ssm start-session '*) : ;;
    'cloudformation delete-stack '*)
      if [[ "${MOCK_DELETE_FAIL:-0}" == 1 ]]; then echo "Mock dependency failure" >&2; return 12; fi ;;
    'cloudformation wait stack-delete-complete '*) : ;;
    *) echo "Unmocked AWS call: $*" >&2; return 92 ;;
  esac
}
terraform() {
  printf 'terraform %s\n' "$*" >> "$CALL_LOG"
  if [[ "${MOCK_CREATE_FAIL:-0}" == 1 && "$*" == *' apply '* ]]; then
    echo "Mock cluster provisioning failure" >&2
    return 13
  fi
  if [[ "${MOCK_DELETE_FAIL:-0}" == 1 && "$*" == *' destroy '* ]]; then
    echo "Mock terraform destroy failure" >&2
    return 12
  fi
  case "$*" in
    *'output -raw vpc_id'*) echo vpc-mock ;;
    *'output -raw bastion_instance_id'*) echo i-mock ;;
    *'output -raw alb_controller_role_arn'*) echo arn:aws:iam::000000000000:role/mock-alb ;;
  esac
}
kubectl() {
  printf 'kubectl %s\n' "$*" >> "$CALL_LOG"
  case "$*" in
    'config view '*)
      if [[ "${MOCK_WRONG_CONTEXT:-0}" == 1 ]]; then echo https://wrong.example; else echo https://mock.eks.example; fi ;;
    *'get vpa vertical-demo '*)
      if [[ "${MOCK_RECOMMENDATION:-0}" == 1 ]]; then echo 100m; fi ;;
    *'get deploy aws-load-balancer-controller'*) return 1 ;;
    *'get ingress '*) echo alb-mock.us-east-2.elb.amazonaws.com ;;
  esac
  return 0
}
curl() {
  printf 'curl %s\n' "$*" >> "$CALL_LOG"
  if [[ "$*" == *http://* ]]; then
    echo "app version ${MOCK_CICD_VERSION:-1}"
  else
    echo 198.51.100.10
  fi
}
docker() { printf 'docker %s\n' "$*" >> "$CALL_LOG"; }
helm() { printf 'helm %s\n' "$*" >> "$CALL_LOG"; }
sleep() { :; }
session-manager-plugin() { :; }
export -f aws terraform kubectl curl docker helm sleep session-manager-plugin

reset_log() { : > "$CALL_LOG"; }
assert_call() { grep -Fq -- "$1" "$CALL_LOG" || { echo "Missing call: $1" >&2; exit 1; }; }
assert_no_call() { if grep -Fq -- "$1" "$CALL_LOG"; then echo "Unexpected call: $1" >&2; exit 1; fi; }
assert_before() {
  local first second
  first="$(grep -n -F -- "$1" "$CALL_LOG" | head -n 1 | cut -d: -f1)"
  second="$(grep -n -F -- "$2" "$CALL_LOG" | head -n 1 | cut -d: -f1)"
  [[ -n "$first" && -n "$second" && "$first" -lt "$second" ]] || {
    echo "Wrong ordering: $1 must precede $2" >&2; exit 1;
  }
}

reset_log
if MOCK_NO_CREDS=1 bash "$WORK/create.sh" > "$WORK/output" 2>&1; then
  echo "Creation ran without AWS credentials" >&2; exit 1
fi
assert_no_call ' apply '

reset_log
bash "$WORK/create.sh" > "$WORK/output" 2>&1
assert_call ' apply '
assert_no_call 'cloudformation'
assert_no_call 'ssm start-session'
assert_no_call 'eksctl'
assert_no_call 'bastion.yaml'
assert_no_call 'cluster.yaml'
grep -q '198.51.100.10/32' "$WORK/.state/lab.tfvars"
grep -q 'test-eks' "$WORK/.state/lab.tfvars"

reset_log
if MOCK_CREATE_FAIL=1 bash "$WORK/create.sh" > "$WORK/output" 2>&1; then
  echo "Creation hid a provisioning error" >&2; exit 1
fi
assert_no_call 'cloudformation'

reset_log
bash "$WORK/destroy.sh" > "$WORK/output" 2>&1
assert_call ' destroy '
assert_no_call 'cloudformation'
assert_no_call 'eksctl'

reset_log
if MOCK_DELETE_FAIL=1 bash "$WORK/destroy.sh" > "$WORK/output" 2>&1; then
  echo "Deletion hid a terraform destroy failure" >&2; exit 1
fi
assert_no_call 'cloudformation'

reset_log
if MOCK_SSM_OFFLINE=1 bash "$WORK/connect-bastion.sh" > "$WORK/output" 2>&1; then
  echo "SSM timeout was ignored" >&2; exit 1
fi
assert_no_call 'aws ssm start-session'

reset_log
if MOCK_WRONG_CONTEXT=1 bash "$WORK/hpa/install-metrics.sh" > "$WORK/output" 2>&1; then
  echo "Wrong cluster context was accepted" >&2; exit 1
fi
assert_no_call 'kubectl apply'

reset_log
if bash "$WORK/hpa/vpa-mode.sh" initial > "$WORK/output" 2>&1; then
  echo "VPA Initial accepted without recommendations" >&2; exit 1
fi
assert_no_call 'rollout restart'

reset_log
MOCK_RECOMMENDATION=1 bash "$WORK/hpa/vpa-mode.sh" initial > "$WORK/output" 2>&1
assert_call '"updateMode":"Initial"'
assert_call 'rollout restart deployment/vertical-demo'

reset_log
if MOCK_WRONG_CONTEXT=1 bash "$WORK/cicd/pipeline.sh" 1 > "$WORK/output" 2>&1; then
  echo "CI/CD ran against the wrong cluster" >&2; exit 1
fi
assert_no_call 'docker build'

reset_log
MOCK_CICD_VERSION=1 bash "$WORK/cicd/pipeline.sh" 1 > "$WORK/output" 2>&1
assert_call 'docker build'
assert_call '--platform linux/amd64'
assert_call 'docker push'
assert_call 'kubectl apply'
assert_call 'helm upgrade --install aws-load-balancer-controller'
assert_no_call 'eksctl'
grep -q 'app version 1' "$WORK/output"

reset_log
MOCK_CICD_VERSION=2 bash "$WORK/cicd/pipeline.sh" 2 > "$WORK/output" 2>&1
assert_call 'nginx-cicd:v2'
grep -q 'app version 2' "$WORK/output"
echo "PASS: 11 mocked lifecycle scenarios; credential gate, terraform apply/destroy, failure propagation, SSM timeout, wrong-context protection, VPA modes, and nginx CI/CD v1 then v2."
