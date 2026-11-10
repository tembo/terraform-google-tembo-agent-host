locals {
  enabled = module.this.enabled

  # The chart's fullname: the release name, suffixed with the chart name
  # unless it already contains it.
  release_fullname = trimsuffix(substr(strcontains(var.release_name, "tembo") ? var.release_name : "${var.release_name}-tembo", 0, 63), "-")

  # Names service accounts "tembo-controller" and "tembo-host" without a name in the context.
  label_name = coalesce(module.this.name, "tembo")

  host_project_id = var.host_project_id != null ? var.host_project_id : var.project_id

  # The controller's --gce-instance-name-prefix default. It names every instance
  # and boot disk, which scopes the controller's mutations in IAM.
  instance_name_prefix = local.enabled ? "tembo-${substr(sha256("${var.cluster_name}/${var.kubernetes_namespace}"), 0, 8)}-" : null
  install_suffix       = local.enabled ? substr(sha256("${var.project_id}/${var.cluster_name}/${var.kubernetes_namespace}"), 0, 8) : null

  # The controller labels every instance with its cluster and namespace,
  # encoded to GCE label rules as the controller encodes them.
  ownership_label_values = local.enabled ? {
    "tembo-cluster"   = replace(lower(var.cluster_name), "/[^a-z0-9_-]/", "-")
    "tembo-namespace" = replace(lower(var.kubernetes_namespace), "/[^a-z0-9_-]/", "-")
  } : {}
  ownership_labels = { for key, value in local.ownership_label_values : key => length(value) > 63 ? "${substr(value, 0, 54)}-${substr(sha256(value), 0, 8)}" : value }

  # projects/<project>/regions/<region>/subnetworks/<name>, optionally as a URL.
  subnetwork_pattern = "^(?:https://(?:www|compute)\\.googleapis\\.com/compute/(?:v1|beta)/)?(?P<path>projects/(?P<project>[^/]+)/regions/(?P<region>[^/]+)/subnetworks/(?P<name>[^/]+))$"
  host_subnetwork    = try(regex(local.subnetwork_pattern, var.host_subnetwork), null)

  cluster                  = one(data.google_container_cluster.this[*])
  cluster_subnetwork       = try(regex(local.subnetwork_pattern, local.cluster.subnetwork), null)
  cluster_workload_pool    = try(local.cluster.workload_identity_config[0].workload_pool, "")
  cluster_private_endpoint = try(local.cluster.private_cluster_config[0].private_endpoint, "")
  cluster_public_endpoint  = try(local.cluster.endpoint, "")

  # Hosts reach the Kubernetes API from their subnetwork, so the private endpoint comes first.
  api_server_url = var.api_server_url != null ? var.api_server_url : (
    local.cluster_private_endpoint != "" ? "https://${local.cluster_private_endpoint}" : (
      local.cluster_public_endpoint != "" ? "https://${local.cluster_public_endpoint}" : null
    )
  )

  # The chart's compute.hostClasses.<name>, for the host_class and helm_values outputs.
  host_class = local.enabled ? {
    gcp = merge(
      {
        machineTypes = var.machine_types
        imageSelectorTerms = [
          var.image != null ? { image = var.image } : var.image_family != null ? { family = var.image_family } : { channel = var.image_channel }
        ]
        subnetwork     = try(local.host_subnetwork.path, null)
        serviceAccount = local.host_service_account_email
        bootDisk = merge(
          { sizeGiB = var.boot_disk_size_gib, type = var.boot_disk_type },
          var.boot_disk_provisioned_iops != null ? { provisionedIops = var.boot_disk_provisioned_iops } : {},
          var.boot_disk_provisioned_throughput != null ? { provisionedThroughputMiBps = var.boot_disk_provisioned_throughput } : {},
          var.boot_disk_kms_key != null ? { kmsKey = var.boot_disk_kms_key } : {},
        )
        localSSDs = var.local_ssd_count
      },
      length(var.zones) > 0 ? { zones = var.zones } : {},
      length(var.network_tags) > 0 ? { networkTags = var.network_tags } : {},
      var.min_cpu_platform != null ? { minCpuPlatform = var.min_cpu_platform } : {},
      length(var.host_labels) > 0 ? { labels = var.host_labels } : {},
    )
  } : null
}

data "google_container_cluster" "this" {
  count = local.enabled ? 1 : 0

  project  = var.project_id
  name     = var.cluster_name
  location = var.cluster_location
}

data "google_compute_subnetwork" "host" {
  count = local.enabled ? 1 : 0

  project = local.host_subnetwork.project
  region  = local.host_subnetwork.region
  name    = local.host_subnetwork.name
}
