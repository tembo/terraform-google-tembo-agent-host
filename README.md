# terraform-google-tembo-agent-host

Terraform module for the Google Cloud resources Tembo's host controller needs to launch agent hosts in your project:
name-scoped IAM for the controller, a host service account, firewall rules and an object storage bucket.

Self-hosted Tembo runs agents in VMs on dedicated Compute Engine instances, not in pods. The host controller, installed
by the `tembo` Helm chart with `compute.mode=controller`, launches and deletes those instances as demand changes, much
like Karpenter does for nodes. This module creates what it needs outside the cluster:

- **Controller service account**: a Google service account for the controller's Kubernetes service account, through
  GKE Workload Identity. It can create instances in the host project, but change and delete only instances and disks
  named with this install's prefix; it launches them only into the host subnetwork and attaches only the host service
  account.
- **Host service account**: the service account agent hosts launch with, with access to the install's bucket and
  optional Cloud Logging and Monitoring roles. Hosts read their configuration from a Kubernetes Secret, not through IAM.
- **Firewall rules**: the host manager port (8743) from the cluster's pods and nodes, and optionally SSH through
  Identity-Aware Proxy, targeting the host service account.
- **Object storage**: a GCS bucket for the install, and a Google service account for the control plane that reads and
  writes it.

The module reads the cluster and the host subnetwork and does not change them.

## Usage

```hcl
module "tembo_agent_host" {
  source  = "tembo/tembo-agent-host/google"
  version = "x.x.x"

  project_id           = "acme-prod"
  cluster_name         = "prod"
  cluster_location     = "us-central1"
  kubernetes_namespace = "tembo"

  host_subnetwork = "projects/acme-prod/regions/us-central1/subnetworks/tembo-agent-hosts"

  # The install's URL, for file uploads to the object storage bucket.
  object_storage_cors_allowed_origins = ["https://tembo.example.com"]

  namespace = "acme"
  name      = "tembo"
}
```

Pass `helm_values` to the `tembo` chart, before your own values so they can override it:

```hcl
resource "helm_release" "tembo" {
  name      = "tembo"
  namespace = "tembo"
  chart     = "tembo-x.y.z.tgz" # The tembo chart from your Tembo release.

  values = [
    yamlencode(module.tembo_agent_host.helm_values),
    file("values.yaml"),
  ]
}
```

`helm_values` sets up the chart's Ingresses for GKE's Ingress (`ingress.gcp`), and installs the controller for Google
Cloud (`cloudProviders: [gcp]`) with this module's service account, the host project and the instance name prefix, and a
host class and pool named `default`: the module's subnetwork, host service account, image and `machine_types` with
`local_ssd_count` local SSDs, one to three hosts. `host_class` is the same class, for adding more.

The class selects Tembo's agent host image by channel (`image_channel`, default `stable`). The host controller sends the
install's license key, project and service account to Tembo's API, which grants the controller's service account
`roles/compute.imageUser` on the channel's image. Set `image_family` or `image` to select an image yourself instead.

The release name and namespace must match `release_name` and `kubernetes_namespace`: the service accounts trust only
the chart's Kubernetes service accounts, and the instance name prefix derives from the cluster name and namespace.

The module needs the Compute Engine, IAM, IAM Service Account Credentials and Cloud Storage APIs
(`compute.googleapis.com`, `iam.googleapis.com`, `iamcredentials.googleapis.com` and `storage.googleapis.com`) enabled
in its projects.

### Workload Identity

The cluster must have Workload Identity on; Autopilot clusters always do. The module binds
`roles/iam.workloadIdentityUser` on each Google service account to its Kubernetes service account,
`serviceAccount:<project>.svc.id.goog[<namespace>/<name>]`, and `helm_values` annotates the chart's service accounts with
`iam.gke.io/gcp-service-account`. No keys are created: the control plane and hosts sign object storage URLs through
the IAM `signBlob` API, with `roles/iam.serviceAccountTokenCreator` on their own service accounts.

New IAM bindings can take a few minutes to take effect. Pods that start before then fail to authenticate and retry.

### IAM scoping

Compute Engine can't scope permissions by labels, so the controller's permissions are scoped by name. Its instances
and their boot disks are named `<prefix><host>-<hash>`, where the prefix (`instance_name_prefix`, such as
`tembo-1a2b3c4d-`) derives from the cluster name and namespace, and `helm_values` passes it to the controller. Three
custom roles in the host project split its permissions:

- **Read**, bound without a condition: get and list instances, machine types, zones, regions, images and the subnetwork,
  and poll zone operations. Listing can't be scoped by name, so the controller can read every instance in the project,
  including its metadata.
- **Launch**, bound without a condition: create instances and disks. Compute Engine checks creation on the project,
  where a name condition can't match, so the controller can create instances of any name in the host project.
- **Manage**, bound with the IAM condition
  `resource.name.extract("/instances/{name}").startsWith("<prefix>") || resource.name.extract("/disks/{name}").startsWith("<prefix>")`:
  delete instances and disks, and set their metadata, labels, network tags and service account.

`roles/compute.networkUser` on the host subnetwork alone and `roles/iam.serviceAccountUser` on the host service account
alone limit where hosts launch and what identity they get. The controller also labels its hosts with their cluster and
namespace (`ownership_labels`), but labels don't authorize anything.

The prefix condition keeps the controller from changing or deleting other instances in a shared project, such as the
GKE nodes, but not from creating instances there. We recommend launching hosts in a project of their own with
`host_project_id`: the controller's roles and the host service account are created there, so it can neither read nor
change anything else, and no other workload can create instances with its prefix.

### Reaching the Kubernetes API

Hosts read their configuration through the cluster's Kubernetes API, at its private endpoint (`apiServerUrl` in
`helm_values`). If the cluster enforces master authorized networks on its private endpoint
(`private_endpoint_enforcement_enabled`), add the host subnetwork's range, the `host_subnetwork_cidr` output, to them.
Hosts in a different region than the cluster need the control plane's global access (`master_global_access_config`).
For a cluster without an IP endpoint, set `api_server_url`.

### Network

Hosts have no external addresses. The host subnetwork needs Cloud NAT for egress to Tembo's API, LLM endpoints, code
hosts and registries, and Private Google Access for Cloud Storage and IAM. A host carries the egress of every session
VM on it, so give the NAT dynamic port allocation with at least 1,024 ports per VM (as `examples/complete` does):
Cloud NAT's default of 64 runs out with a couple of sessions, and agents fail with "Unable to connect". Hosts reach the chart's bundled Postgres
and Redis through internal load balancers (`hostAccess`); an external database or Redis must accept connections from
the host subnetwork.

The manager firewall rule allows the cluster's pod range and its nodes' subnetwork. Add any additional pod ranges, and
any other clients of the host manager, in `manager_ingress_source_ranges`. For a Shared VPC subnetwork, the module
creates the firewall rules and the controller's `roles/compute.networkUser` in the network's host project.

### Permissions to apply

The identity that applies the module needs, besides read access to the cluster (`roles/container.clusterViewer`):

| Project | Roles | For |
| --- | --- | --- |
| `project_id` | `roles/iam.serviceAccountAdmin`, `roles/storage.admin` | The controller and control plane service accounts and their Workload Identity bindings; the bucket and its bindings |
| `host_project_id` | `roles/iam.serviceAccountAdmin`, `roles/iam.roleAdmin`, `roles/resourcemanager.projectIamAdmin` | The host service account; the controller's custom roles and their bindings |
| The host subnetwork's project | `roles/compute.networkAdmin`, `roles/compute.securityAdmin` | The controller's `roles/compute.networkUser` on the subnetwork; the firewall rules |

`roles/owner` covers all of these. `roles/editor` doesn't: it can't create custom roles or set IAM on subnetworks.

### Organization policies and quotas

- `constraints/compute.disableNestedVirtualization` must not be enforced on the host project: hosts run agents in VMs
  with KVM.
- `constraints/compute.trustedImageProjects`, if set, must allow the image's project: Tembo's image project
  (`projects/tembo-prod`) for an image channel, or your own for `image_family` and `image`.
- `constraints/compute.requireShieldedVm` must not be enforced: the agent host image boots with legacy BIOS.
- Hosts need CPU quota for their machine series in the host region (`N2_CPUS` for the default `n2-custom-32-65536`: 32
  per host) and local SSD quota (`LOCAL_SSD_TOTAL_GB`: 375 per local SSD).

### Machine types

Nested virtualization needs an Intel machine series other than E2, such as N2, C3 or C4. The default,
`n2-custom-32-65536`, has 32 vCPUs and 64 GiB with four local SSDs, which hosts stripe for their VM store. For a
`-lssd` machine type, such as `c3-standard-44-lssd`, which includes its local SSDs, set `local_ssd_count = 0`. Series
with a single CPU platform, such as C3 and C4, don't need `min_cpu_platform`: set it to null. C4 also needs
`boot_disk_type = "hyperdisk-balanced"`.

### Object storage

By default the module creates a regional GCS bucket for the install in `project_id`, named from the module's labels
plus a hash of the project, cluster and namespace (bucket names are global): project builds (VM golden
snapshots), file uploads and agent assets. It has uniform bucket-level access, public access prevention, soft delete
off (`object_storage_soft_delete_retention_seconds`) and a rule that aborts multipart uploads left incomplete after 7
days. Agent hosts get access through their service account, and the chart's service account (the API, worker and cron)
through a control plane service account, bound like the controller's. `helm_values` sets the chart's `objectStorage`
values. Pass the install's URL in `object_storage_cors_allowed_origins` so browsers can upload files.

To use an existing bucket, set `object_storage_bucket_name`; the module then manages only access to it. Set
`object_storage_enabled = false` to install without object storage, which turns off project builds and file uploads.

### Existing resources

Set `create_host_service_account = false` with `host_service_account_email` to use your own host service account; the
module grants it the same access, and the controller may attach only it. Set `create_firewall_rules = false` to manage
the firewall yourself.

## Examples

- [`examples/complete`](examples/complete): a VPC with Cloud NAT and Private Google Access, a private GKE Autopilot
  cluster and the module.

## Tests

The Terratest suite in [`test/src`](test/src) applies [`examples/complete`](examples/complete) in the project
`GOOGLE_CLOUD_PROJECT` names, with Application Default Credentials:

```sh
GOOGLE_CLOUD_PROJECT=my-project make -C test/src test
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.5 |
| google | >= 6.0, < 9.0 |

## Providers

| Name | Version |
|------|---------|
| google | >= 6.0, < 9.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| control\_plane\_label | cloudposse/label/null | 0.25.0 |
| controller\_label | cloudposse/label/null | 0.25.0 |
| host\_label | cloudposse/label/null | 0.25.0 |
| storage\_label | cloudposse/label/null | 0.25.0 |
| this | cloudposse/label/null | 0.25.0 |

## Resources

| Name | Type |
|------|------|
| [google_compute_firewall.iap_ssh](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_compute_firewall.manager](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_compute_subnetwork_iam_member.controller](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_subnetwork_iam_member) | resource |
| [google_project_iam_custom_role.controller_launch](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_custom_role) | resource |
| [google_project_iam_custom_role.controller_manage](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_custom_role) | resource |
| [google_project_iam_custom_role.controller_read](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_custom_role) | resource |
| [google_project_iam_member.controller_launch](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.controller_manage](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.controller_read](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.host](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_service_account.control_plane](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account.controller](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account.host](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account_iam_member.control_plane_token_creator](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_service_account_iam_member.control_plane_workload_identity](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_service_account_iam_member.controller_host_user](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_service_account_iam_member.controller_workload_identity](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_service_account_iam_member.host_token_creator](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_storage_bucket.storage](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket) | resource |
| [google_storage_bucket_iam_member.control_plane](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket_iam_member) | resource |
| [google_storage_bucket_iam_member.host](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket_iam_member) | resource |
| [google_compute_subnetwork.cluster](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/compute_subnetwork) | data source |
| [google_compute_subnetwork.host](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/compute_subnetwork) | data source |
| [google_container_cluster.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/container_cluster) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| additional\_tag\_map | Additional key-value pairs to add to each map in `tags_as_list_of_maps`. Not added to `tags` or `id`.<br/>This is for some rare cases where resources want additional configuration of tags<br/>and therefore take a list of maps with tag key, value, and additional configuration. | `map(string)` | `{}` | no |
| api\_server\_url | Kubernetes API URL agent hosts read their configuration through. Defaults to the cluster's private endpoint, or its<br/>public endpoint when it has none. | `string` | `null` | no |
| attributes | ID element. Additional attributes (e.g. `workers` or `cluster`) to add to `id`,<br/>in the order they appear in the list. New attributes are appended to the<br/>end of the list. The elements of the list are joined by the `delimiter`<br/>and treated as a single ID element. | `list(string)` | `[]` | no |
| boot\_disk\_kms\_key | Cloud KMS key boot disks are encrypted with, as `projects/<project>/locations/<location>/keyRings/<ring>/cryptoKeys/<key>`,<br/>instead of a Google-managed key. Grant the host project's Compute Engine service agent<br/>(`service-<project number>@compute-system.iam.gserviceaccount.com`) `roles/cloudkms.cryptoKeyEncrypterDecrypter` on it. | `string` | `null` | no |
| boot\_disk\_provisioned\_iops | IOPS to provision for a `hyperdisk-balanced` boot disk. | `number` | `null` | no |
| boot\_disk\_provisioned\_throughput | Throughput in MiB/s to provision for a `hyperdisk-balanced` boot disk. | `number` | `null` | no |
| boot\_disk\_size\_gib | Size of each host's boot disk in GiB. | `number` | `100` | no |
| boot\_disk\_type | Type of each host's boot disk: `pd-balanced`, `pd-ssd` or `hyperdisk-balanced` (for machine series that only take Hyperdisk, such as C4). | `string` | `"pd-balanced"` | no |
| cluster\_location | Location of the GKE cluster: its region, or its zone for a zonal cluster. | `string` | n/a | yes |
| cluster\_name | Name of the GKE cluster the Tembo install runs in. | `string` | n/a | yes |
| context | Single object for setting entire context at once.<br/>See description of individual variables for details.<br/>Leave string and numeric variables as `null` to use default value.<br/>Individual variable settings (non-null) override settings in context object,<br/>except for attributes, tags, and additional\_tag\_map, which are merged. | `any` | <pre>{<br/>  "additional_tag_map": {},<br/>  "attributes": [],<br/>  "delimiter": null,<br/>  "descriptor_formats": {},<br/>  "enabled": true,<br/>  "environment": null,<br/>  "id_length_limit": null,<br/>  "label_key_case": null,<br/>  "label_order": [],<br/>  "label_value_case": null,<br/>  "labels_as_tags": [<br/>    "unset"<br/>  ],<br/>  "name": null,<br/>  "namespace": null,<br/>  "regex_replace_chars": null,<br/>  "stage": null,<br/>  "tags": {},<br/>  "tenant": null<br/>}</pre> | no |
| control\_plane\_service\_account\_name | Overrides the Kubernetes service account of the chart's API, worker and cron, which the control plane's Google service account is bound to. Defaults to the chart's: the release name when it contains `tembo`, otherwise `<release_name>-tembo`. | `string` | `null` | no |
| create\_firewall\_rules | Create the firewall rules for agent hosts in the host subnetwork's network. | `bool` | `true` | no |
| create\_host\_service\_account | Create the agent host service account. When false, set `host_service_account_email`; the module grants it the same access. | `bool` | `true` | no |
| delimiter | Delimiter to be used between ID elements.<br/>Defaults to `-` (hyphen). Set to `""` to use no delimiter at all. | `string` | `null` | no |
| descriptor\_formats | Describe additional descriptors to be output in the `descriptors` output map.<br/>Map of maps. Keys are names of descriptors. Values are maps of the form<br/>`{<br/>   format = string<br/>   labels = list(string)<br/>}`<br/>(Type is `any` so the map values can later be enhanced to provide additional options.)<br/>`format` is a Terraform format string to be passed to the `format()` function.<br/>`labels` is a list of labels, in order, to pass to `format()` function.<br/>Label values will be normalized before being passed to `format()` so they will be<br/>identical to how they appear in `id`.<br/>Default is `{}` (`descriptors` output will be empty). | `any` | `{}` | no |
| enabled | Set to false to prevent the module from creating any resources | `bool` | `null` | no |
| environment | ID element. Usually used for region e.g. 'uw2', 'us-west-2', OR role 'prod', 'staging', 'dev', 'UAT' | `string` | `null` | no |
| host\_iap\_ssh\_enabled | Allow SSH to hosts through Identity-Aware Proxy TCP forwarding (from 35.235.240.0/20). | `bool` | `false` | no |
| host\_labels | Labels the controller applies to every host, in addition to its ownership labels. Keys and values follow GCE label rules. | `map(string)` | `{}` | no |
| host\_monitoring\_enabled | Grant the host service account `roles/logging.logWriter` and `roles/monitoring.metricWriter` in the host project, for log and metric agents. | `bool` | `false` | no |
| host\_object\_storage\_bucket\_names | Additional GCS buckets agent hosts read and write. The install's object storage bucket is included without listing it here. | `list(string)` | `[]` | no |
| host\_project\_id | Project agent hosts launch in, where the module creates the host service account and the controller's custom roles.<br/>Defaults to `project_id`. A project of their own isolates hosts from other instances, which the controller can list<br/>and read project-wide. | `string` | `null` | no |
| host\_project\_roles | Additional roles for the host service account in the host project. | `list(string)` | `[]` | no |
| host\_service\_account\_email | Existing service account for agent hosts, when `create_host_service_account` is false. The controller may attach only this account. | `string` | `null` | no |
| host\_subnetwork | Subnetwork agent hosts launch into, as `projects/<project>/regions/<region>/subnetworks/<name>` (a subnetwork's `id`).<br/>For a Shared VPC subnetwork, the module creates its firewall rules and grants the controller<br/>`roles/compute.networkUser` on it in the Shared VPC host project. | `string` | n/a | yes |
| id\_length\_limit | Limit `id` to this many characters (minimum 6).<br/>Set to `0` for unlimited length.<br/>Set to `null` for keep the existing setting, which defaults to `0`.<br/>Does not affect `id_full`. | `number` | `null` | no |
| image | Image to select instead of `image_channel`, as a name in the host project or `projects/<project>/global/images/<name>`. | `string` | `null` | no |
| image\_channel | Tembo agent host image channel the default host class in `helm_values` selects. The host controller gets the<br/>channel's image from Tembo's API with the install's license key, which grants the controller's service account use<br/>of it. | `string` | `"stable"` | no |
| image\_family | Image family to select instead of `image_channel`, as a name in the host project or<br/>`projects/<project>/global/images/family/<family>`. The controller may read and use the host project's images;<br/>grant it `roles/compute.imageUser` on another project's. | `string` | `null` | no |
| kubernetes\_namespace | Kubernetes namespace of the Tembo install (the tembo Helm release). | `string` | n/a | yes |
| label\_key\_case | Controls the letter case of the `tags` keys (label names) for tags generated by this module.<br/>Does not affect keys of tags passed in via the `tags` input.<br/>Possible values: `lower`, `title`, `upper`.<br/>Default value: `title`. | `string` | `null` | no |
| label\_order | The order in which the labels (ID elements) appear in the `id`.<br/>Defaults to ["namespace", "environment", "stage", "name", "attributes"].<br/>You can omit any of the 6 labels ("tenant" is the 6th), but at least one must be present. | `list(string)` | `null` | no |
| label\_value\_case | Controls the letter case of ID elements (labels) as included in `id`,<br/>set as tag values, and output by this module individually.<br/>Does not affect values of tags passed in via the `tags` input.<br/>Possible values: `lower`, `title`, `upper` and `none` (no transformation).<br/>Set this to `title` and set `delimiter` to `""` to yield Pascal Case IDs.<br/>Default value: `lower`. | `string` | `null` | no |
| labels\_as\_tags | Set of labels (ID elements) to include as tags in the `tags` output.<br/>Default is to include all labels.<br/>Tags with empty values will not be included in the `tags` output.<br/>Set to `[]` to suppress all generated tags.<br/>**Notes:**<br/>  The value of the `name` tag, if included, will be the `id`, not the `name`.<br/>  Unlike other `null-label` inputs, the initial setting of `labels_as_tags` cannot be<br/>  changed in later chained modules. Attempts to change it will be silently ignored. | `set(string)` | <pre>[<br/>  "default"<br/>]</pre> | no |
| local\_ssd\_count | Local SSDs (375 GiB NVMe each) attached to every host for its VM store. The machine type must allow the count: N2<br/>with 32 vCPUs allows 4, 8, 16 or 24. Set 0 for `-lssd` machine types, which include theirs. | `number` | `4` | no |
| machine\_types | Machine types for the default host class in `helm_values`, in order of preference. They must support nested<br/>virtualization: Intel machine series other than E2, such as N2, C3 and C4. | `list(string)` | <pre>[<br/>  "n2-custom-32-65536"<br/>]</pre> | no |
| manager\_ingress\_source\_ranges | CIDR ranges allowed to reach each host's manager on port 8743, in addition to the cluster's pod range and node<br/>subnetwork. Add any additional pod ranges the cluster uses. | `list(string)` | `[]` | no |
| min\_cpu\_platform | Minimum CPU platform for hosts, such as `Intel Ice Lake`. Null for machine series that take none. | `string` | `"Intel Ice Lake"` | no |
| name | ID element. Usually the component or solution name, e.g. 'app' or 'jenkins'.<br/>This is the only ID element not also included as a `tag`.<br/>The "name" tag is set to the full `id` string. There is no tag with the value of the `name` input. | `string` | `null` | no |
| namespace | ID element. Usually an abbreviation of your organization name, e.g. 'eg' or 'cp', to help ensure generated IDs are globally unique | `string` | `null` | no |
| network\_tags | Network tags for hosts, for your own firewall rules and routes. The module's rules target the host service account instead. | `list(string)` | `[]` | no |
| object\_storage\_bucket\_name | Existing GCS bucket to use instead of creating one. The module then manages only access to it; set its CORS yourself. | `string` | `null` | no |
| object\_storage\_cors\_allowed\_origins | Origins browsers upload files from, such as `https://tembo.example.com`: the install's URL. Without one, file uploads from the browser fail. | `list(string)` | `[]` | no |
| object\_storage\_enabled | Give the install object storage: a GCS bucket for project builds (VM golden snapshots), file uploads and agent<br/>assets, read and write access for agent hosts and the control plane (a service account for the chart's), and the<br/>chart's `objectStorage` values in `helm_values`. Without it, project builds and file uploads are off. | `bool` | `true` | no |
| object\_storage\_force\_destroy | Delete the created bucket's objects when the module is destroyed. | `bool` | `false` | no |
| object\_storage\_location | Location of the created bucket. Defaults to the host subnetwork's region. | `string` | `null` | no |
| object\_storage\_soft\_delete\_retention\_seconds | How long the created bucket keeps deleted objects recoverable, in seconds: 0 (off) or 604800 (7 days) to 7776000 (90<br/>days). Builds replace multi-GB snapshots often, which soft delete would keep and bill. | `number` | `0` | no |
| project\_id | Project of the GKE cluster the Tembo install runs in. The module creates the controller and control plane service accounts and the object storage bucket here. | `string` | n/a | yes |
| regex\_replace\_chars | Terraform regular expression (regex) string.<br/>Characters matching the regex will be removed from the ID elements.<br/>If not set, `"/[^a-zA-Z0-9-]/"` is used to remove all characters other than hyphens, letters and digits. | `string` | `null` | no |
| release\_name | Name of the tembo Helm release, which names the host controller's service account. | `string` | `"tembo"` | no |
| service\_account\_name | Overrides the host controller's Kubernetes service account name. Defaults to the chart's:<br/>`<release_name>-host-controller` when the release name contains `tembo`, otherwise<br/>`<release_name>-tembo-host-controller`. | `string` | `null` | no |
| stage | ID element. Usually used to indicate role, e.g. 'prod', 'staging', 'source', 'build', 'test', 'deploy', 'release' | `string` | `null` | no |
| tags | Additional tags (e.g. `{'BusinessUnit': 'XYZ'}`).<br/>Neither the tag keys nor the tag values will be modified by this module. | `map(string)` | `{}` | no |
| tenant | ID element \_(Rarely used, not included by default)\_. A customer identifier, indicating who this instance of a resource is for | `string` | `null` | no |
| zones | Zones of the host subnetwork's region hosts launch in. Empty uses every zone of the region that is up. | `list(string)` | `[]` | no |

## Outputs

| Name | Description |
|------|-------------|
| control\_plane\_service\_account\_email | Email of the control plane's Google service account, which reads and writes the install's object storage. |
| controller\_service\_account\_email | Email of the host controller's Google service account. |
| firewall\_rule\_names | Firewall rules the module creates for agent hosts. |
| helm\_values | Values for the tembo Helm chart: its Ingresses for GKE's Ingress (`ingress.gcp`), the host controller with this<br/>module's identity, a host class and pool named `default`, and with object storage, the bucket and the control plane's<br/>identity. |
| host\_class | A host class using this module's subnetwork, service account, image and machine types, for the chart's<br/>`compute.hostClasses.<name>`. `helm_values` already sets one named `default`. |
| host\_service\_account\_email | Email of the service account agent hosts launch with. |
| host\_subnetwork\_cidr | Primary range of the host subnetwork. Hosts read their configuration through the cluster's Kubernetes API, so add<br/>it to the cluster's master authorized networks when they apply to its private endpoint. |
| instance\_name\_prefix | Prefix the host controller names its instances and boot disks with, to which its permissions to change and delete them are limited. |
| object\_storage\_bucket\_name | The install's object storage bucket. |
| ownership\_labels | Labels the host controller puts on the instances it manages. |
| service\_account\_name | Host controller Kubernetes service account the Google service account is bound to. |
<!-- END_TF_DOCS -->

## License

[Apache 2.0](LICENSE)
