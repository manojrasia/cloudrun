#!/usr/bin/env bash
# Shared helpers. Reads settings from terraform/terraform.tfvars so nothing is typed twice.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/terraform"
TFVARS="$TF_DIR/terraform.tfvars"

tfvar() {  # tfvar <name> [default]  -> value of name = "value" in terraform.tfvars
  local v
  v=$(sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$TFVARS" 2>/dev/null | head -1)
  echo "${v:-${2:-}}"
}

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' is not installed or not on PATH." >&2; exit 1; }; }

load_config() {
  [ -f "$TFVARS" ] || { echo "ERROR: $TFVARS not found. Run scripts/03-configure.sh first." >&2; exit 1; }
  PROJECT_ID=$(tfvar project_id)
  REGION=$(tfvar region us-central1)
  APP=$(tfvar app shop)
  ENV=$(tfvar env dev)
  DOMAIN=$(tfvar domain)
  GITHUB_REPO=$(tfvar github_repo)
  PREFIX="$APP-$ENV"
  STATE_BUCKET="${PROJECT_ID}-tfstate"
  IMAGES_BUCKET="${PROJECT_ID}-${PREFIX}-images"
  [ -n "$PROJECT_ID" ] || { echo "ERROR: project_id missing in terraform.tfvars" >&2; exit 1; }
}
