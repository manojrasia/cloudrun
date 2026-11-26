# One service account per module, least privilege.
resource "google_service_account" "runtime" {
  for_each     = toset(local.service_names)
  account_id   = "${local.prefix}-${each.key}"
  display_name = "Cloud Run ${each.key} (${var.env})"
}

resource "google_service_account" "pubsub_invoker" {
  account_id   = "${local.prefix}-psub-invoker"
  display_name = "Pub/Sub push identity (${var.env})"
}

resource "google_service_account" "deployer" {
  account_id   = "${local.prefix}-deployer"
  display_name = "GitHub Actions deployer (${var.env})"
}

locals {
  sa_emails = { for k, v in google_service_account.runtime : k => v.email }

  secret_ids = merge(
    { "db-password" = google_secret_manager_secret.db_password.id },
    { for k, s in google_secret_manager_secret.app : k => s.id },
  )

  # Which module may read which secret.
  secret_grants = {
    catalog       = ["db-password"]
    orders        = ["db-password"]
    payments      = ["db-password", "stripe-secret-key", "stripe-webhook-secret"]
    notifications = ["email-api-key"]
  }

  secret_grant_pairs = merge([
    for sa, secrets in local.secret_grants : {
      for s in secrets : "${sa}-${s}" => { sa = sa, secret = s }
    }
  ]...)

  pubsub_agent = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

# Only the modules that talk to Postgres get cloudsql.client.
resource "google_project_iam_member" "sql_client" {
  for_each = toset(["catalog", "orders", "payments"])
  project  = var.project_id
  role     = "roles/cloudsql.client"
  member   = "serviceAccount:${local.sa_emails[each.key]}"
}

resource "google_project_iam_member" "telemetry" {
  for_each = {
    for pair in setproduct(local.service_names, ["roles/logging.logWriter", "roles/cloudtrace.agent", "roles/monitoring.metricWriter"]) :
    "${pair[0]}-${pair[1]}" => { sa = pair[0], role = pair[1] }
  }
  project = var.project_id
  role    = each.value.role
  member  = "serviceAccount:${local.sa_emails[each.value.sa]}"
}

resource "google_secret_manager_secret_iam_member" "grant" {
  for_each  = local.secret_grant_pairs
  secret_id = local.secret_ids[each.value.secret]
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${local.sa_emails[each.value.sa]}"
}

# payments publishes "order paid" events.
resource "google_pubsub_topic_iam_member" "payments_publisher" {
  topic  = google_pubsub_topic.events.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${local.sa_emails["payments"]}"
}

# Pub/Sub service agent: mint OIDC tokens and forward to the DLQ.
resource "google_service_account_iam_member" "pubsub_token_creator" {
  service_account_id = google_service_account.pubsub_invoker.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = local.pubsub_agent
}

resource "google_pubsub_topic_iam_member" "dlq_publisher" {
  topic  = google_pubsub_topic.events_dlq.name
  role   = "roles/pubsub.publisher"
  member = local.pubsub_agent
}

resource "google_pubsub_subscription_iam_member" "dlq_subscriber" {
  subscription = google_pubsub_subscription.events_push.name
  role         = "roles/pubsub.subscriber"
  member       = local.pubsub_agent
}

# Public modules are reachable only through the load balancer (ingress setting); the invoker
# binding to allUsers is required for LB traffic. If your org policy forbids allUsers, front
# the LB with IAP instead.
resource "google_cloud_run_v2_service_iam_member" "public" {
  for_each = toset(local.public_services)
  name     = google_cloud_run_v2_service.svc[each.key].name
  location = var.region
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_service_iam_member" "notifications_invoker" {
  name     = google_cloud_run_v2_service.svc["notifications"].name
  location = var.region
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.pubsub_invoker.email}"
}
