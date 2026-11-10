output "controller_service_account_email" {
  description = "Email of the host controller's Google service account."
  value       = one(google_service_account.controller[*].email)
}

output "service_account_name" {
  description = "Host controller Kubernetes service account the Google service account is bound to."
  value       = local.enabled ? local.service_account_name : null
}

output "host_service_account_email" {
  description = "Email of the service account agent hosts launch with."
  value       = local.enabled ? local.host_service_account_email : null
}

output "control_plane_service_account_email" {
  description = "Email of the control plane's Google service account, which reads and writes the install's object storage."
  value       = one(google_service_account.control_plane[*].email)
}

output "instance_name_prefix" {
  description = "Prefix the host controller names its instances and boot disks with, to which its permissions to change and delete them are limited."
  value       = local.instance_name_prefix
}

output "ownership_labels" {
  description = "Labels the host controller puts on the instances it manages."
  value       = local.ownership_labels
}

output "host_subnetwork_cidr" {
  description = <<-EOT
    Primary range of the host subnetwork. Hosts read their configuration through the cluster's Kubernetes API, so add
    it to the cluster's master authorized networks when they apply to its private endpoint.
    EOT
  value       = one(data.google_compute_subnetwork.host[*].ip_cidr_range)
}

output "firewall_rule_names" {
  description = "Firewall rules the module creates for agent hosts."
  value       = concat(google_compute_firewall.manager[*].name, google_compute_firewall.iap_ssh[*].name)
}

output "object_storage_bucket_name" {
  description = "The install's object storage bucket."
  value       = local.object_storage_bucket_name
}

output "helm_values" {
  description = <<-EOT
    Values for the tembo Helm chart: the host controller with this module's identity, a host class and pool named
    `default`, and with object storage, the bucket and the control plane's identity.
    EOT
  # GKE's metadata server gets a pod's credentials when it asks for them, which
  # fails until the Workload Identity bindings and the roles exist.
  depends_on = [
    google_service_account_iam_member.controller_workload_identity,
    google_project_iam_member.controller_read,
    google_project_iam_member.controller_launch,
    google_project_iam_member.controller_manage,
    google_compute_subnetwork_iam_member.controller,
    google_service_account_iam_member.controller_host_user,
    google_service_account_iam_member.control_plane_workload_identity,
    google_service_account_iam_member.control_plane_token_creator,
    google_storage_bucket_iam_member.control_plane,
  ]
  value = local.enabled ? merge({
    compute = {
      mode = "controller"
      controller = {
        clusterName    = var.cluster_name
        apiServerUrl   = local.api_server_url
        cloudProviders = ["gcp"]
        gcp = {
          project            = local.host_project_id
          instanceNamePrefix = local.instance_name_prefix
        }
        serviceAccount = {
          annotations = { "iam.gke.io/gcp-service-account" = one(google_service_account.controller[*].email) }
        }
      }
      hostClasses = { default = local.host_class }
      hostPools = {
        default = {
          classRef = { name = "default" }
          # Hosts that stay up, ready for sessions.
          minHosts = 1
          maxHosts = 3
          # Free memory to keep for new sessions before adding a host.
          minIdleMemory = "32Gi"
        }
      }
    }
    },
    # A list, empty when off, avoids a conditional between unlike objects.
    [for values in [{
      objectStorage = {
        provider = "gcs"
        bucket   = local.object_storage_bucket_name
      }
      serviceAccount = {
        annotations = { "iam.gke.io/gcp-service-account" = one(google_service_account.control_plane[*].email) }
      }
    }] : values if local.object_storage_enabled]...
  ) : null
}

output "host_class" {
  description = <<-EOT
    A host class using this module's subnetwork, service account, image and machine types, for the chart's
    `compute.hostClasses.<name>`. `helm_values` already sets one named `default`.
    EOT
  value       = local.host_class
}
