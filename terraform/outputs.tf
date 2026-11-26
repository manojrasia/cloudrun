output "lb_ip" {
  description = "Create a DNS A record for var.domain pointing here. The managed cert activates after DNS resolves."
  value       = google_compute_global_address.lb.address
}

output "artifact_registry" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}

output "wif_provider" {
  description = "Set as GitHub variable WIF_PROVIDER."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "deployer_service_account" {
  description = "Set as GitHub variable DEPLOYER_SA."
  value       = google_service_account.deployer.email
}

output "cloud_run_services" {
  value = { for k, s in google_cloud_run_v2_service.svc : k => s.name }
}

output "images_bucket" {
  description = "Upload product images under images/ in this bucket; they are served at https://<domain>/images/..."
  value       = google_storage_bucket.images.name
}

output "stripe_webhook_url" {
  description = "Register this endpoint in the Stripe dashboard (event: payment_intent.succeeded)."
  value       = "https://${var.domain}/api/payments/webhook"
}
