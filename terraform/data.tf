# ---------- Artifact Registry ----------
resource "google_artifact_registry_repository" "images" {
  repository_id = local.prefix
  location      = var.region
  format        = "DOCKER"
  description   = "Container images for ${local.prefix}"

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 20
    }
  }
  cleanup_policies {
    id     = "delete-old-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "604800s"
    }
  }

  depends_on = [google_project_service.apis]
}

# ---------- Cloud SQL (one instance, private IP; schema shared by catalog/orders/payments) ----------
resource "random_password" "db" {
  length  = 32
  special = false
}

resource "google_sql_database_instance" "pg" {
  name                = "${local.prefix}-pg"
  region              = var.region
  database_version    = "POSTGRES_16"
  deletion_protection = false

  settings {
    tier                        = var.db_tier
    edition                     = "ENTERPRISE"
    availability_type           = local.is_prod ? "REGIONAL" : "ZONAL"
    disk_type                   = "PD_SSD"
    disk_autoresize             = true
    deletion_protection_enabled = false
    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.id
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "03:00"
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 14
      }
    }

    maintenance_window {
      day          = 7
      hour         = 4
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled  = true
      record_application_tags = true
    }

    database_flags {
      name  = "log_min_duration_statement"
      value = "500"
    }
  }

  depends_on = [google_service_networking_connection.psa]
}

resource "google_sql_database" "app" {
  name     = "shop"
  instance = google_sql_database_instance.pg.name
}

resource "google_sql_user" "app" {
  name     = "shop"
  instance = google_sql_database_instance.pg.name
  password = random_password.db.result
}

# ---------- Secrets ----------
resource "google_secret_manager_secret" "db_password" {
  secret_id = "${local.prefix}-db-password"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.db.result
}

# Third-party secrets: Terraform creates an empty placeholder. Add the real value as a new
# secret version (see README); Cloud Run reads "latest" and Terraform never overwrites it.
resource "google_secret_manager_secret" "app" {
  for_each  = toset(["email-api-key"])
  secret_id = "${local.prefix}-${each.key}"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "app_placeholder" {
  for_each    = google_secret_manager_secret.app
  secret      = each.value.id
  secret_data = "REPLACE_ME"

  lifecycle {
    ignore_changes = [secret_data, enabled]
  }
}

# ---------- Product images (served through the load balancer + CDN at /images/*) ----------
resource "google_storage_bucket" "images" {
  name                        = "${var.project_id}-${local.prefix}-images"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
  public_access_prevention    = "inherited"

  versioning {
    enabled = true
  }

  cors {
    origin          = ["https://${var.domain}"]
    method          = ["GET", "HEAD"]
    response_header = ["Content-Type"]
    max_age_seconds = 3600
  }

  depends_on = [google_project_service.apis]
}

# Requires an org policy that allows allUsers. Otherwise serve images via a signed-URL or proxy service.
resource "google_storage_bucket_iam_member" "images_public" {
  bucket = google_storage_bucket.images.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# ---------- Pub/Sub: order events -> notifications, with dead-letter queue ----------
resource "google_pubsub_topic" "events" {
  name       = "${local.prefix}-order-events"
  depends_on = [google_project_service.apis]
}

resource "google_pubsub_topic" "events_dlq" {
  name       = "${local.prefix}-order-events-dlq"
  depends_on = [google_project_service.apis]
}

# Pull subscription on the DLQ so backlog is observable and alertable.
resource "google_pubsub_subscription" "events_dlq" {
  name                       = "${local.prefix}-order-events-dlq-pull"
  topic                      = google_pubsub_topic.events_dlq.id
  message_retention_duration = "1209600s"
  ack_deadline_seconds       = 60
}

resource "google_pubsub_subscription" "events_push" {
  name                       = "${local.prefix}-order-events-notifications"
  topic                      = google_pubsub_topic.events.id
  ack_deadline_seconds       = 120
  message_retention_duration = "604800s"

  push_config {
    push_endpoint = "${google_cloud_run_v2_service.svc["notifications"].uri}/pubsub/push"
    oidc_token {
      service_account_email = google_service_account.pubsub_invoker.email
      audience              = google_cloud_run_v2_service.svc["notifications"].uri
    }
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.events_dlq.id
    max_delivery_attempts = 5
  }

  expiration_policy {
    ttl = ""
  }
}
