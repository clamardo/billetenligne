variable "project_id" {
  description = "The GCP project everything below lives in."
  type        = string
}

variable "region" {
  description = <<-EOT
    Where the cluster and the database are.

    `europe-west1` rather than anything in Africa, and it is a real trade: the
    market is the Republic of the Congo and there is no GCP region there, so
    the nearest ones are in Europe either way. Round-trip time from Brazzaville
    is on the order of 150 ms, which the app is already built for — it is
    offline-first, the ticket is signed and cached, and the seat map is one
    request. What this choice does cost is a second of latency on a slow 2G
    handshake, which is why the pages the server renders are single documents
    with the artwork inlined.
  EOT
  type        = string
  default     = "europe-west1"
}

variable "zone" {
  description = <<-EOT
    A single zone for the cluster.

    Zonal rather than regional, deliberately: a regional control plane is three
    times the node cost for a product whose entire market is asleep between
    midnight and four. A zone outage is an outage here, and the honest place to
    say so is this variable rather than a post-mortem.
  EOT
  type        = string
  default     = "europe-west1-b"
}

variable "environment" {
  description = "prod, staging — becomes part of every name."
  type        = string
}

variable "network_name" {
  type    = string
  default = "bel-vpc"
}

variable "subnet_cidr" {
  type    = string
  default = "10.20.0.0/20"
}

variable "cluster_name" {
  type = string
}

variable "kubernetes_namespace" {
  description = "The namespace infra/k8s deploys into. Half of the Workload Identity binding."
  type        = string
  default     = "billetenligne"
}

variable "machine_type" {
  description = "e2-standard-2 is two vCPU and 8 GB, which runs the API twice over, two nginx pods and the passes with room to spare."
  type        = string
  default     = "e2-standard-2"
}

variable "min_node_count" {
  description = <<-EOT
    Two, and it has to be two.

    The manifests spread each deployment one pod per node and hold a
    PodDisruptionBudget of minAvailable 1. On a single-node pool that pair is
    not a safety net, it is a deadlock: the second replica of everything is
    unschedulable, and `auto_upgrade` — which is on — cannot drain the only
    node without violating every budget, so the upgrade waits forever and
    somebody eventually deletes the budgets in a hurry.
  EOT
  type        = number
  default     = 2
}

variable "max_node_count" {
  type    = number
  default = 3
}

variable "use_spot_nodes" {
  description = <<-EOT
    Spot VMs are 60-90% cheaper and can be reclaimed with thirty seconds'
    notice. False for production: the reclaim happens when Google needs the
    capacity, which is the middle of a European working day and the middle of
    the Congolese selling day.
  EOT
  type        = bool
  default     = false
}

variable "sql_instance_name" {
  type = string
}

variable "sql_tier" {
  description = "db-custom-1-3840 is one vCPU and 3.75 GB — a whole market's timetable is small, and the working set is one day of departures."
  type        = string
  default     = "db-custom-1-3840"
}

variable "database_version" {
  description = "Postgres 17, matching what the migrations are checked against in CI."
  type        = string
  default     = "POSTGRES_17"
}

variable "database_name" {
  type    = string
  default = "billetenligne"
}

variable "sql_owner_user" {
  description = <<-EOT
    The role the migrations run as, and the only one that may create schema.

    **Not the role the API uses.** `bel_api` is created by the migrations
    themselves, NOLOGIN and NOINHERIT, and holds no privileges at all until a
    transaction declares a surface (ADR-0011, migration 0005). Terraform must
    not create it: a Cloud SQL user of that name would be an *inheriting* role,
    the migration's `IF NOT EXISTS` would politely skip it, and every request
    would then run with the union of the public, tenant and platform
    privileges. `verify.sql` asserts against exactly that.
  EOT
  type        = string
  default     = "bel"
}

variable "sql_owner_password" {
  type      = string
  sensitive = true
}

variable "deletion_protection" {
  description = "On for anything holding a real ticket."
  type        = bool
  default     = true
}

variable "master_authorized_networks" {
  description = "Who may reach the cluster's control plane. Empty means anywhere, which is the state a first deploy starts in and should not stay in."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

variable "common_labels" {
  type    = map(string)
  default = {}
}

variable "secret_names" {
  description = <<-EOT
    Every secret the deployment reads, by name. The same list as the keys in
    infra/k8s/secrets.example.yaml and infra/k8s/secretproviderclass.yaml, and
    CI fails when the three disagree — a secret the pods mount and the project
    does not have is a pod that never starts.
  EOT
  type        = list(string)
  default = [
    "AIRTEL__CLIENTID",
    "AIRTEL__CLIENTSECRET",
    "AIRTEL__DISBURSEMENTPIN",
    "CARD__APIKEY",
    "CARD__SITEID",
    "COMMS__CONNECTIONSTRING",
    "DATABASE_URL",
    "FIREBASE_CLIENT_EMAIL",
    "FIREBASE_PRIVATE_KEY",
    "MIGRATE_DATABASE_URL",
    "MTN__APIKEY",
    "MTN__APIUSER",
    "MTN__DISBURSEMENTAPIKEY",
    "MTN__DISBURSEMENTKEY",
    "MTN__DISBURSEMENTUSER",
    "MTN__SUBSCRIPTIONKEY",
    "ORANGE__CLIENTID",
    "ORANGE__CLIENTSECRET",
    "ORANGE__MERCHANTKEY",
    "STORAGE__KEY",
    "TICKETS__SIGNINGSEED",
    "TOTP__ENCRYPTIONKEY",
  ]
}
