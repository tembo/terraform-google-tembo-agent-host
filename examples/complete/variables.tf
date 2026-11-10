variable "project_id" {
  type        = string
  description = "Project the example creates its network, cluster and the module's resources in."
}

variable "region" {
  type        = string
  description = "Region of the network, cluster and hosts."
}

variable "kubernetes_namespace" {
  type        = string
  description = "Namespace the tembo chart is installed in."
}
