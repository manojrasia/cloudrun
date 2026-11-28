#!/usr/bin/env bash
# README step 7: push this folder to GitHub (main) and set the variables the deploy workflow reads.
# Usage: scripts/07-github.sh [--push]    (--push also commits and pushes to origin/main)
source "$(dirname "$0")/lib.sh"; need gh; need terraform; load_config
[ -n "$GITHUB_REPO" ] || { echo "github_repo missing in terraform.tfvars"; exit 1; }
if [ "${1:-}" = "--push" ]; then
  cd "$ROOT"
  git add -A
  git diff --cached --quiet || git commit -m "Replace Stripe with dummy payments"
  git branch -M main
  git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$GITHUB_REPO.git"
  git push -u origin main
fi
cd "$TF_DIR"
gh variable set GCP_PROJECT_ID  -R "$GITHUB_REPO" --body "$PROJECT_ID"
gh variable set GCP_REGION      -R "$GITHUB_REPO" --body "$REGION"
gh variable set RESOURCE_PREFIX -R "$GITHUB_REPO" --body "$PREFIX"
gh variable set WIF_PROVIDER    -R "$GITHUB_REPO" --body "$(terraform output -raw wif_provider)"
gh variable set DEPLOYER_SA     -R "$GITHUB_REPO" --body "$(terraform output -raw deployer_service_account)"
echo "Step 7 done."
