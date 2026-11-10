# The service account agent hosts launch with. Hosts read their configuration
# from the Kubernetes API, not through Google IAM, so it only carries object
# storage access and optional extras: Cloud Logging and Monitoring, and any
# project roles.

locals {
  host_service_account_email = var.create_host_service_account ? one(google_service_account.host[*].email) : var.host_service_account_email
  host_service_account_id = var.create_host_service_account ? one(google_service_account.host[*].name) : (
    var.host_service_account_email != null ? "projects/-/serviceAccounts/${var.host_service_account_email}" : null
  )
  host_service_account_member = local.host_service_account_email != null ? "serviceAccount:${local.host_service_account_email}" : null

  host_project_roles = concat(
    var.host_monitoring_enabled ? ["roles/logging.logWriter", "roles/monitoring.metricWriter"] : [],
    var.host_project_roles,
  )
}

module "host_label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  name            = local.label_name
  attributes      = ["host"]
  id_length_limit = 30

  context = module.this.context
}

resource "google_service_account" "host" {
  count = local.enabled && var.create_host_service_account ? 1 : 0

  project      = local.host_project_id
  account_id   = module.host_label.id
  display_name = module.host_label.id
  description  = "Tembo agent hosts launched by ${var.kubernetes_namespace}/${local.service_account_name} in ${var.cluster_name}"
}

# Hosts sign object storage URLs with signBlob, without a key.
resource "google_service_account_iam_member" "host_token_creator" {
  count = local.enabled ? 1 : 0

  service_account_id = local.host_service_account_id
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = local.host_service_account_member
}

resource "google_project_iam_member" "host" {
  for_each = local.enabled ? toset(local.host_project_roles) : []

  project = local.host_project_id
  role    = each.value
  member  = local.host_service_account_member
}

resource "google_storage_bucket_iam_member" "host" {
  for_each = local.enabled ? toset(local.host_object_storage_bucket_names) : []

  bucket = each.value
  role   = "roles/storage.objectAdmin"
  member = local.host_service_account_member
}
