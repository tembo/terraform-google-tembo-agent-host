variable "project_id" {
  type        = string
  description = "Project of the GKE cluster the Tembo install runs in. The module creates the controller and control plane service accounts and the object storage bucket here."
}

variable "cluster_name" {
  type        = string
  description = "Name of the GKE cluster the Tembo install runs in."
}

variable "cluster_location" {
  type        = string
  description = "Location of the GKE cluster: its region, or its zone for a zonal cluster."
}

variable "kubernetes_namespace" {
  type        = string
  description = "Kubernetes namespace of the Tembo install (the tembo Helm release)."
}

variable "release_name" {
  type        = string
  description = "Name of the tembo Helm release, which names the host controller's service account."
  default     = "tembo"
}

variable "service_account_name" {
  type        = string
  description = <<-EOT
    Overrides the host controller's Kubernetes service account name. Defaults to the chart's:
    `<release_name>-host-controller` when the release name contains `tembo`, otherwise
    `<release_name>-tembo-host-controller`.
    EOT
  default     = null
}

variable "control_plane_service_account_name" {
  type        = string
  description = "Overrides the Kubernetes service account of the chart's API, worker and cron, which the control plane's Google service account is bound to. Defaults to the chart's: the release name when it contains `tembo`, otherwise `<release_name>-tembo`."
  default     = null
}

variable "api_server_url" {
  type        = string
  description = <<-EOT
    Kubernetes API URL agent hosts read their configuration through. Defaults to the cluster's private endpoint, or its
    public endpoint when it has none.
    EOT
  default     = null
}

variable "host_project_id" {
  type        = string
  description = <<-EOT
    Project agent hosts launch in, where the module creates the host service account and the controller's custom roles.
    Defaults to `project_id`. A project of their own isolates hosts from other instances, which the controller can list
    and read project-wide.
    EOT
  default     = null
}

variable "host_subnetwork" {
  type        = string
  description = <<-EOT
    Subnetwork agent hosts launch into, as `projects/<project>/regions/<region>/subnetworks/<name>` (a subnetwork's `id`).
    For a Shared VPC subnetwork, the module creates its firewall rules and grants the controller
    `roles/compute.networkUser` on it in the Shared VPC host project.
    EOT

  validation {
    condition     = var.host_subnetwork == null || can(regex("^(?:https://(?:www|compute)\\.googleapis\\.com/compute/(?:v1|beta)/)?projects/[^/]+/regions/[^/]+/subnetworks/[^/]+$", var.host_subnetwork))
    error_message = "host_subnetwork must be projects/<project>/regions/<region>/subnetworks/<name>."
  }
}

variable "zones" {
  type        = list(string)
  description = "Zones of the host subnetwork's region hosts launch in. Empty uses every zone of the region that is up."
  default     = []
}

variable "machine_types" {
  type        = list(string)
  description = <<-EOT
    Machine types for the default host class in `helm_values`, in order of preference. They must support nested
    virtualization: Intel machine series other than E2, such as N2, C3 and C4.
    EOT
  default     = ["n2-custom-32-65536"]

  validation {
    condition     = length(var.machine_types) >= 1 && length(var.machine_types) <= 20
    error_message = "Set 1 to 20 machine types."
  }
}

variable "local_ssd_count" {
  type        = number
  description = <<-EOT
    Local SSDs (375 GiB NVMe each) attached to every host for its VM store. The machine type must allow the count: N2
    with 32 vCPUs allows 4, 8, 16 or 24. Set 0 for `-lssd` machine types, which include theirs.
    EOT
  default     = 4

  validation {
    condition     = var.local_ssd_count >= 0 && var.local_ssd_count <= 24 && floor(var.local_ssd_count) == var.local_ssd_count
    error_message = "local_ssd_count must be a whole number from 0 to 24."
  }
}

variable "min_cpu_platform" {
  type        = string
  description = "Minimum CPU platform for hosts, such as `Intel Ice Lake`. Null for machine series that take none."
  default     = "Intel Ice Lake"
}

variable "image_channel" {
  type        = string
  description = <<-EOT
    Tembo agent host image channel the default host class in `helm_values` selects. The host controller gets the
    channel's image from Tembo's API with the install's license key, which grants the controller's service account use
    of it.
    EOT
  default     = "stable"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.image_channel))
    error_message = "image_channel must be lowercase letters, digits and dashes."
  }
}

variable "image_family" {
  type        = string
  description = <<-EOT
    Image family to select instead of `image_channel`, as a name in the host project or
    `projects/<project>/global/images/family/<family>`. The controller may read and use the host project's images;
    grant it `roles/compute.imageUser` on another project's.
    EOT
  default     = null

  validation {
    condition     = var.image_family == null || can(regex("^(?:projects/[^/]+/global/images/family/)?[a-z](?:[-a-z0-9]*[a-z0-9])?$", var.image_family))
    error_message = "image_family must be a family name or projects/<project>/global/images/family/<family>."
  }
}

variable "image" {
  type        = string
  description = "Image to select instead of `image_channel`, as a name in the host project or `projects/<project>/global/images/<name>`."
  default     = null

  validation {
    condition     = var.image == null || can(regex("^(?:projects/[^/]+/global/images/)?[a-z](?:[-a-z0-9]*[a-z0-9])?$", var.image))
    error_message = "image must be an image name or projects/<project>/global/images/<name>."
  }
}

variable "boot_disk_size_gib" {
  type        = number
  description = "Size of each host's boot disk in GiB."
  default     = 100

  validation {
    condition     = var.boot_disk_size_gib >= 20
    error_message = "boot_disk_size_gib must be at least 20."
  }
}

variable "boot_disk_type" {
  type        = string
  description = "Type of each host's boot disk: `pd-balanced`, `pd-ssd` or `hyperdisk-balanced` (for machine series that only take Hyperdisk, such as C4)."
  default     = "pd-balanced"

  validation {
    condition     = contains(["pd-balanced", "pd-ssd", "hyperdisk-balanced"], var.boot_disk_type)
    error_message = "boot_disk_type must be pd-balanced, pd-ssd or hyperdisk-balanced."
  }
}

variable "boot_disk_provisioned_iops" {
  type        = number
  description = "IOPS to provision for a `hyperdisk-balanced` boot disk."
  default     = null
}

variable "boot_disk_provisioned_throughput" {
  type        = number
  description = "Throughput in MiB/s to provision for a `hyperdisk-balanced` boot disk."
  default     = null
}

variable "boot_disk_kms_key" {
  type        = string
  description = <<-EOT
    Cloud KMS key boot disks are encrypted with, as `projects/<project>/locations/<location>/keyRings/<ring>/cryptoKeys/<key>`,
    instead of a Google-managed key. Grant the host project's Compute Engine service agent
    (`service-<project number>@compute-system.iam.gserviceaccount.com`) `roles/cloudkms.cryptoKeyEncrypterDecrypter` on it.
    EOT
  default     = null
}

variable "network_tags" {
  type        = list(string)
  description = "Network tags for hosts, for your own firewall rules and routes. The module's rules target the host service account instead."
  default     = []
}

variable "host_labels" {
  type        = map(string)
  description = "Labels the controller applies to every host, in addition to its ownership labels. Keys and values follow GCE label rules."
  default     = {}
}

variable "create_host_service_account" {
  type        = bool
  description = "Create the agent host service account. When false, set `host_service_account_email`; the module grants it the same access."
  default     = true
}

variable "host_service_account_email" {
  type        = string
  description = "Existing service account for agent hosts, when `create_host_service_account` is false. The controller may attach only this account."
  default     = null
}

variable "host_monitoring_enabled" {
  type        = bool
  description = "Grant the host service account `roles/logging.logWriter` and `roles/monitoring.metricWriter` in the host project, for log and metric agents."
  default     = false
}

variable "host_project_roles" {
  type        = list(string)
  description = "Additional roles for the host service account in the host project."
  default     = []
}

variable "host_object_storage_bucket_names" {
  type        = list(string)
  description = "Additional GCS buckets agent hosts read and write. The install's object storage bucket is included without listing it here."
  default     = []
}

variable "create_firewall_rules" {
  type        = bool
  description = "Create the firewall rules for agent hosts in the host subnetwork's network."
  default     = true
}

variable "manager_ingress_source_ranges" {
  type        = list(string)
  description = <<-EOT
    CIDR ranges allowed to reach each host's manager on port 8743, in addition to the cluster's pod range and node
    subnetwork. Add any additional pod ranges the cluster uses.
    EOT
  default     = []
}

variable "host_iap_ssh_enabled" {
  type        = bool
  description = "Allow SSH to hosts through Identity-Aware Proxy TCP forwarding (from 35.235.240.0/20)."
  default     = false
}

variable "object_storage_enabled" {
  type        = bool
  description = <<-EOT
    Give the install object storage: a GCS bucket for project builds (VM golden snapshots), file uploads and agent
    assets, read and write access for agent hosts and the control plane (a service account for the chart's), and the
    chart's `objectStorage` values in `helm_values`. Without it, project builds and file uploads are off.
    EOT
  default     = true
}

variable "object_storage_bucket_name" {
  type        = string
  description = "Existing GCS bucket to use instead of creating one. The module then manages only access to it; set its CORS yourself."
  default     = null
}

variable "object_storage_location" {
  type        = string
  description = "Location of the created bucket. Defaults to the host subnetwork's region."
  default     = null
}

variable "object_storage_cors_allowed_origins" {
  type        = list(string)
  description = "Origins browsers upload files from, such as `https://tembo.example.com`: the install's URL. Without one, file uploads from the browser fail."
  default     = []
}

variable "object_storage_force_destroy" {
  type        = bool
  description = "Delete the created bucket's objects when the module is destroyed."
  default     = false
}

variable "object_storage_soft_delete_retention_seconds" {
  type        = number
  description = <<-EOT
    How long the created bucket keeps deleted objects recoverable, in seconds: 0 (off) or 604800 (7 days) to 7776000 (90
    days). Builds replace multi-GB snapshots often, which soft delete would keep and bill.
    EOT
  default     = 0

  validation {
    condition     = var.object_storage_soft_delete_retention_seconds == 0 || (var.object_storage_soft_delete_retention_seconds >= 604800 && var.object_storage_soft_delete_retention_seconds <= 7776000)
    error_message = "object_storage_soft_delete_retention_seconds must be 0 or from 604800 to 7776000."
  }
}
