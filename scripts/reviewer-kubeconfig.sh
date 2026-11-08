#!/usr/bin/env bash
set -Eeuo pipefail

HOST="${1:?usage: $0 <k8s-node-ip> [output-file] [ssh-key]}"
OUT="${2:-reviewer-kubeconfig.yaml}"
KEY="${3:-$HOME/.ssh/hello-nginx-deploy}"

remote() { ssh -i "$KEY" -o BatchMode=yes "ec2-user@${HOST}" "$@"; }

TOKEN="$(remote "kubectl -n kube-system get secret reviewer-token -o jsonpath='{.data.token}'" | base64 -d)"
CA="$(remote "kubectl -n kube-system get secret reviewer-token -o jsonpath='{.data.ca\\.crt}'")"
[[ -n "$TOKEN" && -n "$CA" ]] || { echo "reviewer-token is not ready yet (is cluster-config synced?)" >&2; exit 1; }

umask 077
cat > "$OUT" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: hello-k3s
    cluster:
      server: https://${HOST}:6443
      certificate-authority-data: ${CA}
users:
  - name: reviewer
    user:
      token: ${TOKEN}
contexts:
  - name: hello-k3s-readonly
    context:
      cluster: hello-k3s
      user: reviewer
current-context: hello-k3s-readonly
EOF
echo "Wrote ${OUT} (read-only). Try: KUBECONFIG=${OUT} kubectl get pods -A"
