output "cluster_name" {
  description = "Name of the example cluster."
  value       = one(google_container_cluster.this[*].name)
}

output "controller_service_account_email" {
  description = "Email of the host controller's Google service account."
  value       = module.agent_host.controller_service_account_email
}

output "service_account_name" {
  description = "Host controller Kubernetes service account the Google service account is bound to."
  value       = module.agent_host.service_account_name
}

output "host_service_account_email" {
  description = "Email of the service account agent hosts launch with."
  value       = module.agent_host.host_service_account_email
}

output "control_plane_service_account_email" {
  description = "Email of the control plane's Google service account."
  value       = module.agent_host.control_plane_service_account_email
}

output "instance_name_prefix" {
  description = "Prefix the host controller names its instances and boot disks with."
  value       = module.agent_host.instance_name_prefix
}

output "ownership_labels" {
  description = "Labels the host controller puts on its instances."
  value       = module.agent_host.ownership_labels
}

output "host_subnetwork_cidr" {
  description = "Primary range of the host subnetwork, for the cluster's master authorized networks."
  value       = module.agent_host.host_subnetwork_cidr
}

output "object_storage_bucket_name" {
  description = "The install's object storage bucket."
  value       = module.agent_host.object_storage_bucket_name
}

output "helm_values" {
  description = "Values for the tembo Helm chart."
  value       = module.agent_host.helm_values
}

output "host_class" {
  description = "A host class for the chart's `compute.hostClasses.<name>`."
  value       = module.agent_host.host_class
}
