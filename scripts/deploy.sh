#!/usr/bin/env bash
set -euo pipefail
export AWS_PAGER=""
PREFIX="${PREFIX:-ethnus-mocktest-01}"
REGION="${REGION:-us-east-1}"

cd "$(dirname "$0")"

# ensure terraform
if ! command -v terraform >/dev/null 2>&1; then
  mkdir -p "$HOME/bin"
  TFV="1.6.6"
  curl -sSLo /tmp/tf.zip "https://releases.hashicorp.com/terraform/${TFV}/terraform_${TFV}_linux_amd64.zip"
  unzip -o /tmp/tf.zip -d "$HOME/bin" >/dev/null
  export PATH="$HOME/bin:$PATH"
fi

echo "init"
terraform init -no-color -upgrade >/dev/null

echo "apply"
terraform apply -no-color -compact-warnings -auto-approve   -var "region=${REGION}" -var "prefix=${PREFIX}" >/dev/null

echo "summary"
terraform output -no-color summary
