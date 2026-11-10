# Firewall rules for agent hosts, in the host subnetwork's project (the Shared
# VPC host project for a shared subnetwork). They target the host service
# account rather than network tags, which anyone who can set tags can change.
# Egress uses the network's implied allow rule.

locals {
  create_firewall_rules = local.enabled && var.create_firewall_rules

  # Pods reach hosts from their own addresses on a VPC-native cluster, and
  # host-network pods from the nodes'.
  manager_ingress_source_ranges = concat(
    compact([
      try(local.cluster.cluster_ipv4_cidr, ""),
      try(data.google_compute_subnetwork.cluster[0].ip_cidr_range, ""),
    ]),
    var.manager_ingress_source_ranges,
  )
}

data "google_compute_subnetwork" "cluster" {
  count = local.create_firewall_rules ? 1 : 0

  project = local.cluster_subnetwork.project
  region  = local.cluster_subnetwork.region
  name    = local.cluster_subnetwork.name
}

resource "google_compute_firewall" "manager" {
  count = local.create_firewall_rules ? 1 : 0

  project                 = local.host_subnetwork.project
  name                    = "${module.host_label.id}-manager"
  description             = "Host manager API on Tembo agent hosts from the Tembo API and host controller (${var.kubernetes_namespace} in ${var.cluster_name})"
  network                 = one(data.google_compute_subnetwork.host[*].network)
  direction               = "INGRESS"
  source_ranges           = local.manager_ingress_source_ranges
  target_service_accounts = [local.host_service_account_email]

  allow {
    protocol = "tcp"
    ports    = ["8743"]
  }
}

# SSH through Identity-Aware Proxy TCP forwarding, whose connections come from
# this range.
resource "google_compute_firewall" "iap_ssh" {
  count = local.create_firewall_rules && var.host_iap_ssh_enabled ? 1 : 0

  project                 = local.host_subnetwork.project
  name                    = "${module.host_label.id}-iap-ssh"
  description             = "SSH to Tembo agent hosts through Identity-Aware Proxy (${var.kubernetes_namespace} in ${var.cluster_name})"
  network                 = one(data.google_compute_subnetwork.host[*].network)
  direction               = "INGRESS"
  source_ranges           = ["35.235.240.0/20"]
  target_service_accounts = [local.host_service_account_email]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
