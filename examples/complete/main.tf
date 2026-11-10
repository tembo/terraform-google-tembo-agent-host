# A VPC with a subnetwork for GKE (with pod and service ranges) and one for
# agent hosts, Cloud NAT for their egress, a private GKE Autopilot cluster, and
# the module.

locals {
  enabled = module.this.enabled

  nodes_cidr    = "10.0.0.0/20"
  pods_cidr     = "10.4.0.0/14"
  services_cidr = "10.8.0.0/20"
  hosts_cidr    = "10.16.0.0/20"
}

resource "google_project_service" "this" {
  for_each = local.enabled ? toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    # Signed URLs are signed with signBlob, without a key.
    "iamcredentials.googleapis.com",
    "storage.googleapis.com",
  ]) : []

  service            = each.value
  disable_on_destroy = false
}

resource "google_compute_network" "this" {
  count = local.enabled ? 1 : 0

  name                    = module.this.id
  auto_create_subnetworks = false

  depends_on = [google_project_service.this]
}

# Both subnetworks reach Google APIs (GCS, IAM, Artifact Registry) without
# external addresses through Private Google Access.
resource "google_compute_subnetwork" "gke" {
  count = local.enabled ? 1 : 0

  name                     = "${module.this.id}-gke"
  network                  = one(google_compute_network.this[*].id)
  ip_cidr_range            = local.nodes_cidr
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = local.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = local.services_cidr
  }
}

resource "google_compute_subnetwork" "hosts" {
  count = local.enabled ? 1 : 0

  name                     = "${module.this.id}-hosts"
  network                  = one(google_compute_network.this[*].id)
  ip_cidr_range            = local.hosts_cidr
  private_ip_google_access = true
}

# Nodes and hosts have no external addresses. Cloud NAT gives them egress to
# Tembo's API, LLM endpoints, code hosts and registries.
resource "google_compute_router" "this" {
  count = local.enabled ? 1 : 0

  name    = module.this.id
  network = one(google_compute_network.this[*].id)
}

resource "google_compute_router_nat" "this" {
  count = local.enabled ? 1 : 0

  name                               = module.this.id
  router                             = one(google_compute_router.this[*].name)
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

module "cluster_label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  attributes = ["cluster"]
  # GKE cluster names are at most 40 characters.
  id_length_limit = 40

  context = module.this.context
}

# A private Autopilot cluster without a public IP endpoint. Its private endpoint
# enforces the authorized networks, which include the host subnetwork: hosts
# read their configuration through the Kubernetes API. Operators reach the
# cluster through its DNS endpoint.
resource "google_container_cluster" "this" {
  count = local.enabled ? 1 : 0

  name             = module.cluster_label.id
  location         = var.region
  enable_autopilot = true
  network          = one(google_compute_network.this[*].id)
  subnetwork       = one(google_compute_subnetwork.gke[*].id)

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = true
  }

  master_authorized_networks_config {
    private_endpoint_enforcement_enabled = true

    cidr_blocks {
      cidr_block   = local.nodes_cidr
      display_name = "GKE nodes"
    }

    cidr_blocks {
      cidr_block   = local.pods_cidr
      display_name = "GKE pods"
    }

    cidr_blocks {
      cidr_block   = local.hosts_cidr
      display_name = "Tembo agent hosts"
    }
  }

  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }
  }

  deletion_protection = false
}

module "agent_host" {
  source = "../.."

  project_id           = var.project_id
  cluster_name         = one(google_container_cluster.this[*].name)
  cluster_location     = one(google_container_cluster.this[*].location)
  kubernetes_namespace = var.kubernetes_namespace
  host_subnetwork      = one(google_compute_subnetwork.hosts[*].id)

  # Destroying the example deletes whatever was uploaded to its bucket.
  object_storage_force_destroy = true

  context = module.this.context
}
