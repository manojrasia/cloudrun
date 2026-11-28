resource "google_compute_global_address" "lb" {
  name       = "${local.prefix}-lb-ip"
  depends_on = [google_project_service.apis]
}

# ---------- Hostname ----------
# No public DNS? sslip.io is a free wildcard DNS service: 34-120-1-2.sslip.io resolves to 34.120.1.2.
# With use_sslip_domain = true the hostname is built from the load balancer IP, so one apply is enough.
variable "use_sslip_domain" {
  description = "Use <ip-with-dashes>.sslip.io as the hostname instead of var.domain."
  type        = bool
  default     = true
}

locals {
  lb_domain = var.use_sslip_domain ? "${replace(google_compute_global_address.lb.address, ".", "-")}.sslip.io" : var.domain
}

output "lb_ip_address" {
  value = google_compute_global_address.lb.address
}

output "lb_https_url" {
  value = "https://${local.lb_domain}"
}

# ---------- Cloud Armor ----------

# Rules that use CEL expressions (including evaluatePreconfiguredWaf) count against the
# SECURITY_POLICY_CEVAL_RULES quota. That quota is 0 on this project, so these rules are
# gated behind a flag. Request the quota increase in IAM & Admin -> Quotas, then set
# enable_cel_rules = true and apply again.
variable "enable_cloud_armor" {
  description = "Create the Cloud Armor policy and attach it to the backends (needs SECURITY_POLICY_RULES quota)."
  type        = bool
  default     = false
}

variable "enable_cel_rules" {
  description = "Create Cloud Armor rules that use CEL expressions (needs SECURITY_POLICY_CEVAL_RULES quota)."
  type        = bool
  default     = false
}

locals {
  armor_cel_rules = {
    1000 = {
      action      = "deny(403)"
      description = "SQL injection"
      expression  = "evaluatePreconfiguredWaf('sqli-v33-stable', {'sensitivity': 1})"
    }
    1010 = {
      action      = "deny(403)"
      description = "Cross-site scripting"
      expression  = "evaluatePreconfiguredWaf('xss-v33-stable', {'sensitivity': 1})"
    }
    1020 = {
      action      = "deny(403)"
      description = "Remote code execution / protocol attacks"
      expression  = "evaluatePreconfiguredWaf('rce-v33-stable', {'sensitivity': 1}) || evaluatePreconfiguredWaf('protocolattack-v33-stable', {'sensitivity': 1})"
    }
  }
}

resource "google_compute_security_policy" "edge" {
  count = var.enable_cloud_armor ? 1 : 0

  name       = "${local.prefix}-edge"
  description = "WAF + rate limiting for the public load balancer"

  adaptive_protection_config {
    layer_7_ddos_defense_config {
      enable = true
    }
  }

  # WAF rules (1000-1020); only created when the quota exists.
  dynamic "rule" {
    for_each = var.enable_cel_rules ? local.armor_cel_rules : {}
    # Only meaningful when enable_cloud_armor = true (the whole policy is skipped otherwise).
    content {
      priority    = tonumber(rule.key)
      action      = rule.value.action
      description = rule.value.description
      match {
        expr {
          expression = rule.value.expression
        }
      }
    }
  }

  rule {
    priority    = 900
    action      = "throttle"
    description = "Per-IP rate limit"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = var.armor_rate_limit_per_minute
        interval_sec = 60
      }
    }
  }

  rule {
    priority    = 2147483647
    action      = "allow"
    description = "Default allow"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}

# ---------- Serverless NEGs + backends ----------
resource "google_compute_region_network_endpoint_group" "neg" {
  for_each              = toset(local.public_services)
  name                  = "${local.prefix}-${each.key}-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_v2_service.svc[each.key].name
  }
}

resource "google_compute_backend_service" "be" {
  for_each              = toset(local.public_services)
  name                  = "${local.prefix}-${each.key}-be"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  security_policy       = var.enable_cloud_armor ? google_compute_security_policy.edge[0].id : null
  enable_cdn            = each.key == "storefront"

  dynamic "cdn_policy" {
    for_each = each.key == "storefront" ? [1] : []
    content {
      cache_mode                   = "CACHE_ALL_STATIC"
      default_ttl                  = 3600
      signed_url_cache_max_age_sec = 3600
      serve_while_stale            = 86400
      negative_caching             = true
    }
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }

  backend {
    group = google_compute_region_network_endpoint_group.neg[each.key].id
  }
}

# ---------- URL map, TLS, forwarding rules ----------
resource "google_compute_backend_bucket" "images" {
  name        = "${local.prefix}-images-be"
  bucket_name = google_storage_bucket.images.name
  enable_cdn  = true

  cdn_policy {
    cache_mode        = "CACHE_ALL_STATIC"
    default_ttl       = 86400
    serve_while_stale = 86400
  }
}

resource "google_compute_url_map" "https" {
  name            = "${local.prefix}-https"
  default_service = google_compute_backend_service.be["storefront"].id

  host_rule {
    hosts        = [local.lb_domain]
    path_matcher = "main"
  }

  path_matcher {
    name            = "main"
    default_service = google_compute_backend_service.be["storefront"].id

    path_rule {
      paths   = ["/api/products", "/api/products/*"]
      service = google_compute_backend_service.be["catalog"].id
    }
    path_rule {
      paths   = ["/api/orders", "/api/orders/*"]
      service = google_compute_backend_service.be["orders"].id
    }
    path_rule {
      paths   = ["/api/payments", "/api/payments/*"]
      service = google_compute_backend_service.be["payments"].id
    }
    path_rule {
      paths   = ["/images/*"]
      service = google_compute_backend_bucket.images.id
    }
  }
}

resource "google_compute_managed_ssl_certificate" "cert" {
  name = "shop-prod-cert-${substr(md5(var.domain), 0, 6)}"

  managed {
    domains = [var.domain]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_ssl_policy" "modern" {
  name            = "${local.prefix}-tls"
  profile         = "MODERN"
  min_tls_version = "TLS_1_2"
}

resource "google_compute_target_https_proxy" "https" {
  name             = "${local.prefix}-https-proxy"
  url_map          = google_compute_url_map.https.id
  ssl_certificates = [google_compute_managed_ssl_certificate.cert.id]
  ssl_policy       = google_compute_ssl_policy.modern.id
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = "${local.prefix}-https"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.lb.address
  port_range            = "443"
  target                = google_compute_target_https_proxy.https.id
}

resource "google_compute_url_map" "redirect" {
  name = "${local.prefix}-http-redirect"
  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "redirect" {
  name    = "${local.prefix}-http-proxy"
  url_map = google_compute_url_map.redirect.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "${local.prefix}-http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.lb.address
  port_range            = "80"
  target                = google_compute_target_http_proxy.redirect.id
}
