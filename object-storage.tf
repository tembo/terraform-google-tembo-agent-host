# The install's object storage: one bucket for project builds (VM golden
# snapshots), file uploads and agent assets. Agent hosts and the control plane
# get read and write access; browsers upload through signed URLs, so the
# bucket allows the install's origins.

locals {
  object_storage_enabled = local.enabled && var.object_storage_enabled
  create_object_storage  = local.object_storage_enabled && var.object_storage_bucket_name == null
  # Read from the created bucket, so access to it is granted after it exists.
  object_storage_bucket_name = local.create_object_storage ? one(google_storage_bucket.storage[*].name) : (
    local.object_storage_enabled ? var.object_storage_bucket_name : null
  )

  host_object_storage_bucket_names = concat(compact([local.object_storage_bucket_name]), var.host_object_storage_bucket_names)

  # The context's tags as GCS labels: lowercase letters, digits, underscores and dashes.
  storage_labels = {
    for key, value in module.storage_label.tags :
    substr(replace(lower(key), "/[^a-z0-9_-]/", "_"), 0, 63) => substr(replace(lower(value), "/[^a-z0-9_-]/", "-"), 0, 63)
  }
}

module "storage_label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  name       = local.label_name
  attributes = ["storage"]
  # Leaves room for the install suffix within the 63-character limit.
  id_length_limit = 54

  context = module.this.context
}

resource "google_storage_bucket" "storage" {
  count = local.create_object_storage ? 1 : 0

  project = var.project_id
  # Bucket names are global: the suffix keeps installs with the same labels apart.
  name                        = "${module.storage_label.id}-${local.install_suffix}"
  location                    = var.object_storage_location != null ? var.object_storage_location : upper(local.host_subnetwork.region)
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = var.object_storage_force_destroy
  labels                      = local.storage_labels

  # Builds replace multi-GB snapshots, which soft delete would keep and bill.
  soft_delete_policy {
    retention_duration_seconds = var.object_storage_soft_delete_retention_seconds
  }

  # Snapshots upload in parts; drop parts an interrupted upload leaves behind.
  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "AbortIncompleteMultipartUpload"
    }
  }

  dynamic "cors" {
    for_each = length(var.object_storage_cors_allowed_origins) > 0 ? [1] : []
    content {
      origin          = var.object_storage_cors_allowed_origins
      method          = ["GET", "PUT", "HEAD"]
      response_header = ["Content-Type", "x-goog-content-sha256", "ETag"]
      max_age_seconds = 3600
    }
  }
}
