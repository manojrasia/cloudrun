#!/usr/bin/env bash
# README "Cleaning up": terraform destroy. In prod, turn off deletion protection first.
source "$(dirname "$0")/lib.sh"; need terraform; load_config
cd "$TF_DIR"; terraform destroy
echo "The state bucket gs://$STATE_BUCKET is separate - delete it yourself if you no longer need it."
