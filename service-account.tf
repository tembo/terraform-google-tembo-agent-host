# Google service accounts for the chart's Kubernetes service accounts, bound by
# GKE Workload Identity: the host controller's, which launches and deletes agent
# hosts named with this install's prefix and may attach only the host service
# account, and the control plane's (the API, worker and cron), which reads and
# writes the install's object storage.

locals {
  service_account_name               = coalesce(var.service_account_name, "${local.release_fullname}-host-controller")
  control_plane_service_account_name = coalesce(var.control_plane_service_account_name, local.release_fullname)

  # Creating an instance and its boot disk is checked on the project, where a
  # name condition can't match, so these are granted project-wide.
  controller_launch_permissions = [
    "compute.disks.create",
    "compute.instances.create",
  ]

  # Permissions checked on the instance and its boot disk, which shares the
  # instance's name: scoped to the install's prefix.
  controller_manage_permissions = [
    "compute.disks.delete",
    "compute.disks.setLabels",
    "compute.disks.use",
    "compute.instances.delete",
    "compute.instances.setLabels",
    "compute.instances.setMetadata",
    "compute.instances.setServiceAccount",
    "compute.instances.setTags",
  ]

  # Listing and polling can't be scoped by name, and images include the
  # project's own families. Tembo's API grants its channel images per image.
  controller_read_permissions = [
    "compute.images.get",
    "compute.images.getFromFamily",
    "compute.images.list",
    "compute.images.useReadOnly",
    "compute.instances.get",
    "compute.instances.list",
    "compute.machineTypes.get",
    "compute.machineTypes.list",
    "compute.regions.get",
    "compute.subnetworks.get",
    "compute.zoneOperations.get",
    "compute.zones.get",
    "compute.zones.list",
  ]

  controller_manage_condition = local.enabled ? join(" || ", [
    for collection in ["instances", "disks"] : "resource.name.extract(\"/${collection}/{name}\").startsWith(\"${local.instance_name_prefix}\")"
  ]) : null
}

module "controller_label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  name       = local.label_name
  attributes = ["controller"]
  # Service account IDs are 6 to 30 characters.
  id_length_limit = 30

  context = module.this.context
}

module "control_plane_label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  name            = local.label_name
  attributes      = ["control-plane"]
  id_length_limit = 30

  context = module.this.context
}

# The host controller's service account. It launches and deletes agent hosts
# named with the instance name prefix, and may attach only the host service
# account.
resource "google_service_account" "controller" {
  count = local.enabled ? 1 : 0

  project      = var.project_id
  account_id   = module.controller_label.id
  display_name = module.controller_label.id
  description  = "Tembo host controller for ${var.kubernetes_namespace}/${local.service_account_name} in ${var.cluster_name}"

  lifecycle {
    precondition {
      condition     = local.host_subnetwork != null
      error_message = "Set host_subnetwork to projects/<project>/regions/<region>/subnetworks/<name>."
    }
    precondition {
      condition     = alltrue([for zone in var.zones : startswith(zone, "${try(local.host_subnetwork.region, "")}-")])
      error_message = "zones must be in the host subnetwork's region."
    }
    precondition {
      condition     = var.image == null || var.image_family == null
      error_message = "Set at most one of image and image_family."
    }
    precondition {
      condition     = var.create_host_service_account || var.host_service_account_email != null
      error_message = "Set host_service_account_email when create_host_service_account is false."
    }
    precondition {
      condition     = local.cluster_workload_pool != ""
      error_message = "The cluster must have Workload Identity enabled."
    }
    precondition {
      condition     = local.api_server_url != null
      error_message = "The cluster has no IP endpoint for hosts to reach. Set api_server_url."
    }
  }
}

resource "google_service_account_iam_member" "controller_workload_identity" {
  count = local.enabled ? 1 : 0

  service_account_id = one(google_service_account.controller[*].name)
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.cluster_workload_pool}[${var.kubernetes_namespace}/${local.service_account_name}]"
}

resource "google_project_iam_custom_role" "controller_read" {
  count = local.enabled ? 1 : 0

  project     = local.host_project_id
  role_id     = replace("${module.controller_label.id}-read", "-", "_")
  title       = "Tembo host controller: read"
  description = "Reads agent hosts and the resources they launch with, for ${var.kubernetes_namespace}/${local.service_account_name} in ${var.cluster_name}"
  permissions = local.controller_read_permissions
}

resource "google_project_iam_member" "controller_read" {
  count = local.enabled ? 1 : 0

  project = local.host_project_id
  role    = one(google_project_iam_custom_role.controller_read[*].name)
  member  = one(google_service_account.controller[*].member)
}

resource "google_project_iam_custom_role" "controller_launch" {
  count = local.enabled ? 1 : 0

  project     = local.host_project_id
  role_id     = replace("${module.controller_label.id}-launch", "-", "_")
  title       = "Tembo host controller: launch hosts"
  description = "Creates agent host instances and their boot disks, for ${var.kubernetes_namespace}/${local.service_account_name} in ${var.cluster_name}"
  permissions = local.controller_launch_permissions
}

resource "google_project_iam_member" "controller_launch" {
  count = local.enabled ? 1 : 0

  project = local.host_project_id
  role    = one(google_project_iam_custom_role.controller_launch[*].name)
  member  = one(google_service_account.controller[*].member)
}

resource "google_project_iam_custom_role" "controller_manage" {
  count = local.enabled ? 1 : 0

  project     = local.host_project_id
  role_id     = replace("${module.controller_label.id}-manage", "-", "_")
  title       = "Tembo host controller: manage hosts"
  description = "Configures and deletes agent hosts, for ${var.kubernetes_namespace}/${local.service_account_name} in ${var.cluster_name}"
  permissions = local.controller_manage_permissions
}

resource "google_project_iam_member" "controller_manage" {
  count = local.enabled ? 1 : 0

  project = local.host_project_id
  role    = one(google_project_iam_custom_role.controller_manage[*].name)
  member  = one(google_service_account.controller[*].member)

  condition {
    title       = "Instances named ${local.instance_name_prefix}*"
    description = "Agent hosts of ${var.kubernetes_namespace} in ${var.cluster_name}, and their boot disks"
    expression  = local.controller_manage_condition
  }
}

resource "google_compute_subnetwork_iam_member" "controller" {
  count = local.enabled ? 1 : 0

  project    = local.host_subnetwork.project
  region     = local.host_subnetwork.region
  subnetwork = local.host_subnetwork.name
  role       = "roles/compute.networkUser"
  member     = one(google_service_account.controller[*].member)
}

resource "google_service_account_iam_member" "controller_host_user" {
  count = local.enabled ? 1 : 0

  service_account_id = local.host_service_account_id
  role               = "roles/iam.serviceAccountUser"
  member             = one(google_service_account.controller[*].member)
}

# The control plane's service account: the API, worker and cron, which share
# the chart's service account, read and write the install's object storage and
# sign its URLs.
resource "google_service_account" "control_plane" {
  count = local.object_storage_enabled ? 1 : 0

  project      = var.project_id
  account_id   = module.control_plane_label.id
  display_name = module.control_plane_label.id
  description  = "Tembo control plane (${var.kubernetes_namespace}/${local.control_plane_service_account_name} in ${var.cluster_name}): object storage"
}

resource "google_service_account_iam_member" "control_plane_workload_identity" {
  count = local.object_storage_enabled ? 1 : 0

  service_account_id = one(google_service_account.control_plane[*].name)
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.cluster_workload_pool}[${var.kubernetes_namespace}/${local.control_plane_service_account_name}]"
}

# Signed upload and download URLs are signed with signBlob, without a key.
resource "google_service_account_iam_member" "control_plane_token_creator" {
  count = local.object_storage_enabled ? 1 : 0

  service_account_id = one(google_service_account.control_plane[*].name)
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = one(google_service_account.control_plane[*].member)
}

resource "google_storage_bucket_iam_member" "control_plane" {
  count = local.object_storage_enabled ? 1 : 0

  bucket = local.object_storage_bucket_name
  role   = "roles/storage.objectAdmin"
  member = one(google_service_account.control_plane[*].member)
}
