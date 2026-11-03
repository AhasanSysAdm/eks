#!/bin/bash
set -euo pipefail
fallocate -l 512M /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
dnf install -y awscli2 jq git tar gzip openssl
systemctl enable --now amazon-ssm-agent
cd /tmp
curl -fsSLo kubectl https://dl.k8s.io/release/v1.35.0/bin/linux/arm64/kubectl
curl -fsSLo kubectl.sha256 https://dl.k8s.io/release/v1.35.0/bin/linux/arm64/kubectl.sha256
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
install -m 0755 kubectl /usr/local/bin/kubectl
curl -fsSLO https://get.helm.sh/helm-v3.19.0-linux-arm64.tar.gz
curl -fsSLO https://get.helm.sh/helm-v3.19.0-linux-arm64.tar.gz.sha256sum
sha256sum --check helm-v3.19.0-linux-arm64.tar.gz.sha256sum
tar -xzf helm-v3.19.0-linux-arm64.tar.gz
install -m 0755 linux-arm64/helm /usr/local/bin/helm
runuser -l ec2-user -c 'aws eks update-kubeconfig --region ${region} --name ${cluster_name} --alias ${cluster_name}'
rm -f kubectl kubectl.sha256 helm-v3.19.0-linux-arm64.tar.gz helm-v3.19.0-linux-arm64.tar.gz.sha256sum
