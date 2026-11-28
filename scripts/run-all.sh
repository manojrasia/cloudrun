#!/usr/bin/env bash
# Runs every step in order. Steps 3 (edit config) and 7/8 need you at the keyboard the first time.
# Usage: scripts/run-all.sh [--from N]   e.g. --from 4 to resume at step 4
set -euo pipefail
cd "$(dirname "$0")"
FROM=1; [ "${1:-}" = "--from" ] && FROM="${2:-1}"
run() { local n=$1; shift; [ "$n" -ge "$FROM" ] && { echo; echo "===== STEP $n ====="; "$@"; } || true; }
run 1  ./01-login.sh
run 2  ./02-state-bucket.sh
run 3  ./03-configure.sh
if [ "$FROM" -le 3 ]; then read -r -p "terraform.tfvars and backend.hcl are correct? Press Enter to continue "; fi
run 4  ./04-terraform.sh
run 5  ./05-dns.sh --wait
run 6  ./06-secrets.sh
run 7  ./07-github.sh --push
run 8  ./08-deploy.sh
run 9  ./09-images.sh
run 10 ./10-test.sh
echo; echo "All steps finished."
