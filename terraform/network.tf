resource "google_compute_network" "vpc" {
  name                    = "${local.prefix}-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

# Subnet used by Cloud Run Direct VPC egress (no Serverless VPC Access connector needed).
resource "google_compute_subnetwork" "run" {
  name                     = "${local.prefix}-run"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.10.0.0/24"
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.25
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Private Service Access range shared by Cloud SQL and Memorystore.
resource "google_compute_global_address" "psa" {
  name          = "${local.prefix}-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa.name]
}

resource "google_compute_firewall" "deny_ingress" {
  name      = "${local.prefix}-deny-all-ingress"
  network   = google_compute_network.vpc.name
  direction = "INGRESS"
  priority  = 65000

  deny {
    protocol = "all"
  }
  source_ranges = ["0.0.0.0/0"]
}
