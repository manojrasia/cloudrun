#!/usr/bin/env bash
# README step 8: run the build-and-deploy workflow and wait for it to finish.
source "$(dirname "$0")/lib.sh"; need gh; load_config
gh workflow run build-and-deploy -R "$GITHUB_REPO" --ref main
sleep 8
RUN_ID=$(gh run list -R "$GITHUB_REPO" --workflow build-and-deploy --limit 1 --json databaseId -q '.[0].databaseId')
echo "Watching run $RUN_ID ..."
gh run watch "$RUN_ID" -R "$GITHUB_REPO" --exit-status
echo "Step 8 done."
