locals {
  db_env = {
    DB_HOST = google_sql_database_instance.pg.private_ip_address
    DB_NAME = google_sql_database.app.name
    DB_USER = google_sql_user.app.name
  }

  db_secret = { DB_PASSWORD = google_secret_manager_secret.db_password.secret_id }

  services = {
    storefront = {
      ingress     = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
      min         = local.is_prod ? 1 : 0
      max         = 10
      concurrency = 250
      memory      = "512Mi"
      timeout     = "30s"
      vpc         = false
      env         = {}
      secret_env  = {}
    }
    catalog = {
      ingress     = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
      min         = local.is_prod ? 1 : 0
      max         = 10
      concurrency = 80
      memory      = "512Mi"
      timeout     = "30s"
      vpc         = true
      env         = local.db_env
      secret_env  = local.db_secret
    }
    orders = {
      ingress     = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
      min         = local.is_prod ? 1 : 0
      max         = 10
      concurrency = 80
      memory      = "512Mi"
      timeout     = "30s"
      vpc         = true
      env         = local.db_env
      secret_env  = local.db_secret
    }
    payments = {
      ingress     = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
      min         = 0
      max         = 10
      concurrency = 40
      memory      = "512Mi"
      timeout     = "60s"
      vpc         = true
      env = merge(local.db_env, {
        PUBSUB_TOPIC            = google_pubsub_topic.events.id
        STRIPE_PUBLISHABLE_KEY  = var.stripe_publishable_key
      })
      secret_env = merge(local.db_secret, {
        STRIPE_SECRET_KEY     = google_secret_manager_secret.app["stripe-secret-key"].secret_id
        STRIPE_WEBHOOK_SECRET = google_secret_manager_secret.app["stripe-webhook-secret"].secret_id
      })
    }
    notifications = {
      # Only Pub/Sub can reach it. No VPC egress: it calls the email provider over the internet.
      ingress     = "INGRESS_TRAFFIC_INTERNAL_ONLY"
      min         = 0
      max         = 10
      concurrency = 10
      memory      = "512Mi"
      timeout     = "120s"
      vpc         = false
      env = {
        EMAIL_FROM = var.email_from
        SHOP_NAME  = var.shop_name
      }
      secret_env = {
        EMAIL_API_KEY = google_secret_manager_secret.app["email-api-key"].secret_id
      }
    }
  }
}

resource "google_cloud_run_v2_service" "svc" {
  for_each = local.services

  name                = "${local.prefix}-${each.key}"
  location            = var.region
  ingress             = each.value.ingress
  deletion_protection = false
  launch_stage        = "GA"

  template {
    service_account                  = local.sa_emails[each.key]
    execution_environment            = "EXECUTION_ENVIRONMENT_GEN2"
    max_instance_request_concurrency = each.value.concurrency
    timeout                          = each.value.timeout

    scaling {
      min_instance_count = each.value.min
      max_instance_count = each.value.max
    }

    dynamic "vpc_access" {
      for_each = each.value.vpc ? [1] : []
      content {
        egress = "PRIVATE_RANGES_ONLY"
        network_interfaces {
          network    = google_compute_network.vpc.id
          subnetwork = google_compute_subnetwork.run.id
        }
      }
    }

    containers {
      image = var.bootstrap_image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = each.value.memory
        }
        cpu_idle          = each.value.min == 0
        startup_cpu_boost = true
      }

      dynamic "env" {
        for_each = each.value.env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = each.value.secret_env
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }

      # TCP startup probe so the placeholder bootstrap image (no /healthz) can start on first apply.
      startup_probe {
        tcp_socket {
          port = 8080
        }
        period_seconds    = 3
        failure_threshold = 20
      }

      liveness_probe {
        http_get {
          path = "/healthz"
        }
        period_seconds    = 15
        failure_threshold = 3
      }
    }
  }

  # CI/CD owns the image and revision; Terraform owns everything else.
  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      template[0].revision,
      template[0].labels,
      client,
      client_version,
    ]
  }

  depends_on = [
    google_project_service.apis,
    google_secret_manager_secret_version.db_password,
    google_secret_manager_secret_version.app_placeholder,
    google_secret_manager_secret_iam_member.grant,
  ]
}

# Schema + seed job (catalog image). CI runs it before every deploy; it is idempotent.
resource "google_cloud_run_v2_job" "migrate" {
  name                = "${local.prefix}-migrate"
  location            = var.region
  deletion_protection = false

  template {
    template {
      service_account = local.sa_emails["catalog"]
      max_retries     = 1
      timeout         = "600s"

      vpc_access {
        egress = "PRIVATE_RANGES_ONLY"
        network_interfaces {
          network    = google_compute_network.vpc.id
          subnetwork = google_compute_subnetwork.run.id
        }
      }

      containers {
        image   = var.bootstrap_image
        command = ["python", "migrate.py"]

        dynamic "env" {
          for_each = local.db_env
          content {
            name  = env.key
            value = env.value
          }
        }
        env {
          name = "DB_PASSWORD"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.db_password.secret_id
              version = "latest"
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[0].image,
      client,
      client_version,
    ]
  }
}
