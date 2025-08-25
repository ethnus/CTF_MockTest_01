#!/usr/bin/env bash
set -euo pipefail
export AWS_PAGER=""
PREFIX="${PREFIX:-ethnus-mocktest-01}"
REGION="${REGION:-us-east-1}"

cd "$(dirname "$0")"

# Validate AWS credentials before proceeding
echo "validating AWS credentials..."
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "ERROR: AWS credentials not configured or expired"
  echo "Please configure AWS CLI or check your AWS Academy Learner Lab session"
  exit 1
fi

# ensure terraform
if ! command -v terraform >/dev/null 2>&1; then
  echo "installing terraform..."
  mkdir -p "$HOME/bin"
  TFV="1.9.8"  # Updated to more recent stable version
  
  # Detect platform for correct Terraform download
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) echo "ERROR: Unsupported architecture: $ARCH"; exit 1 ;;
  esac
  
  OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$OS" in
    linux|darwin) ;;
    *) echo "ERROR: Unsupported OS: $OS"; exit 1 ;;
  esac
  
  TF_URL="https://releases.hashicorp.com/terraform/${TFV}/terraform_${TFV}_${OS}_${ARCH}.zip"
  curl -sSLo /tmp/tf.zip "$TF_URL"
  unzip -o /tmp/tf.zip -d "$HOME/bin" >/dev/null
  export PATH="$HOME/bin:$PATH"
  echo "terraform $TFV installed for ${OS}/${ARCH}"
fi

echo "init"
# Backup existing state file if it exists
if [ -f "terraform.tfstate" ]; then
  cp terraform.tfstate "terraform.tfstate.backup.$(date +%Y%m%d_%H%M%S)"
  echo "existing state file backed up"
fi
terraform init -no-color -upgrade >/dev/null

echo "apply"
if ! terraform apply -no-color -compact-warnings -auto-approve -var "region=${REGION}" -var "prefix=${PREFIX}"; then
  echo "ERROR: Terraform apply failed"
  echo "Check for resource conflicts or run: bash teardown.sh"
  exit 1
fi

echo "summary"
terraform output -no-color summary
