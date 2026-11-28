#!/usr/bin/env bash
# README step 9: upload the product images.
source "$(dirname "$0")/lib.sh"; need gcloud; load_config
gcloud storage cp "$ROOT"/images/*.jpg "gs://$IMAGES_BUCKET/images/"
echo "Step 9 done."
