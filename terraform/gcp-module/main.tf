# BilletEnLigne on GCP: a network, a cluster, a database and a registry.
#
# **What is deliberately not here.** No object store and no messaging: the KYB
# documents, the operator logos and the ticket PDFs live in Azure Blob, and the
# email and SMS go through Azure Communication Services (ADR-0019). That is a
# real split across two clouds and it is not an accident of history — it is
# where the accounts and the sender identities are. `terraform/azure-module`
# holds that half.
#
# No Redis. Nothing in this system caches across processes: the seat hold is a
# row with a lock, the idempotency ledger is a table, and the rate limiter is
# per host in one process. An empty Redis is a monthly bill for a diagram.

# ── Network ─────────────────────────────────────────────────────────────────

resource "google_compute_network" "vpc" {
  name                    = var.network_name
  auto_create_subnetworks = false
  project                 = var.project_id
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.network_name}-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.vpc.id
  project       = var.project_id

  # So private nodes can reach Artifact Registry without leaving Google's
  # network — which is most of what they pull, on every roll.
  private_ip_google_access = true
}

# Private Service Access, which is how Cloud SQL gets an address on this VPC
# rather than a public one.
resource "google_compute_global_address" "private_ip_range" {
  name          = "${var.network_name}-private-ip"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
  project       = var.project_id
}

resource "google_service_networking_connection" "private_vpc" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]
}

resource "google_compute_router" "router" {
  name    = "${var.network_name}-router"
  region  = var.region
  network = google_compute_network.vpc.id
  project = var.project_id
}

# Private nodes have no external address, and this system's nodes have to
# reach several things that are not Google: an Azure storage account, an Azure
# Communication Services endpoint, and one day four mobile-money hosts. Without
# NAT the pods come up and every outbound call times out — which looks like a
# broken adapter and is a missing route.
resource "google_compute_router_nat" "nat" {
  name                               = "${var.network_name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  project                            = var.project_id
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# The address on the posters. Reserved here rather than by the Ingress, so it
# survives the Ingress being deleted and recreated — a printed QR code does
# not get a second chance.
resource "google_compute_global_address" "ingress" {
  name         = "bel-static-ip"
  address_type = "EXTERNAL"
  project      = var.project_id
}

# ── Registry ────────────────────────────────────────────────────────────────

resource "google_artifact_registry_repository" "docker" {
  location      = var.region
  repository_id = "bel"
  description   = "BilletEnLigne images: api, worker, console, admin"
  format        = "DOCKER"
  project       = var.project_id
  labels        = var.common_labels
}

# ── Cluster ─────────────────────────────────────────────────────────────────

resource "google_service_account" "nodes" {
  account_id   = "${var.cluster_name}-nodes"
  display_name = "GKE nodes for ${var.cluster_name}"
  project      = var.project_id
}

resource "google_project_iam_member" "nodes" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/artifactregistry.reader",
  ])
  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

# The identity the pods run as, and the binding that makes it theirs.
#
# Workload Identity is enabled on the cluster below, and that is not a
# convenience — it takes the node service account *away* from the pods. A pod
# on the `default` Kubernetes service account then has no Google credentials
# at all, and the first call to a Google API fails in the metadata server with
# an error that says nothing about service accounts. So the pair exists from
# the start: `bel` in Kubernetes (infra/k8s/serviceaccount.yaml) is bound to
# `bel-workload@PROJECT` here.
#
# **It holds no roles.** An identity that exists and can do nothing is the
# correct starting point; inventing permissions now, for a call nobody has
# written, is how a workload ends up with roles/editor. The first thing that
# needs one — Secret Manager, most likely — adds exactly that one.
resource "google_service_account" "workload" {
  account_id   = "bel-workload"
  display_name = "BilletEnLigne workloads"
  project      = var.project_id
}

resource "google_service_account_iam_member" "workload" {
  service_account_id = google_service_account.workload.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.kubernetes_namespace}/bel]"
}

# The secrets, as containers with nothing in them.
#
# **No `google_secret_manager_secret_version` here, and that is the whole
# point.** A version resource takes the value as an argument, and Terraform
# writes every argument into state — which for this configuration is a GCS
# bucket. Creating the secrets in Terraform and the *values* by hand is what
# keeps a signing seed and a database password out of a file that half the
# team can read and that no one thinks of as sensitive:
#
#   printf %s "$SEED" | gcloud secrets versions add TICKETS__SIGNINGSEED --data-file=-
#
# `printf` rather than `echo`, because `echo` appends a newline and a
# DATABASE_URL with one fails to connect with an error about the host. (The
# API strips trailing newlines when it reads a mounted secret, for exactly
# that reason — but the value in the project should still be the value.)
resource "google_secret_manager_secret" "secrets" {
  for_each  = toset(var.secret_names)
  secret_id = each.key
  project   = var.project_id

  replication {
    auto {}
  }

  lifecycle {
    # A secret is deleted by a person who meant to, in the console. Terraform
    # removing one because a name moved in a list would take the value with
    # it, and there is no undo.
    prevent_destroy = true
  }
}

# Read access, per secret rather than per project. `roles/secretmanager.
# secretAccessor` at the project level would also grant every secret somebody
# adds later for something else.
resource "google_secret_manager_secret_iam_member" "workload" {
  for_each  = google_secret_manager_secret.secrets
  project   = var.project_id
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.workload.email}"
}

resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.zone
  project  = var.project_id

  # A cluster cannot be created with no node pool, and a pool managed by the
  # cluster resource cannot be changed without replacing the cluster.
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.subnet.id

  private_cluster_config {
    enable_private_nodes = true
    # The control plane keeps a public endpoint, so a deploy can reach it from
    # a laptop without a bastion. `master_authorized_networks` is how that is
    # narrowed, and leaving it empty is a decision somebody should make on
    # purpose rather than by not reading this file.
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  dynamic "master_authorized_networks_config" {
    for_each = length(var.master_authorized_networks) > 0 ? [1] : []
    content {
      dynamic "cidr_blocks" {
        for_each = var.master_authorized_networks
        content {
          cidr_block   = cidr_blocks.value.cidr_block
          display_name = cidr_blocks.value.display_name
        }
      }
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus { enabled = true }
  }

  ip_allocation_policy {}

  # KEDA is **not** here, and cannot be: the GKE add-on has no Terraform field
  # yet. The worker does not run without it, so this is a step in the README
  # and a line in this file rather than a surprise on the first night:
  #
  #   gcloud container clusters update <cluster> --location <zone> --enable-keda
  #
  # A ScaledJob applied to a cluster without KEDA is accepted by the API server
  # as an unknown kind and never runs — which is the quietest failure in this
  # whole deployment.

  deletion_protection = var.deletion_protection

  lifecycle {
    ignore_changes = [node_config, network, subnetwork]
  }
}

resource "google_container_node_pool" "primary" {
  name     = "${var.cluster_name}-pool"
  location = var.zone
  cluster  = google_container_cluster.primary.name
  project  = var.project_id

  initial_node_count = var.min_node_count

  autoscaling {
    min_node_count = var.min_node_count
    max_node_count = var.max_node_count
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    spot         = var.use_spot_nodes
    machine_type = var.machine_type
    disk_size_gb = 50
    disk_type    = "pd-balanced"

    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = var.common_labels
    tags   = ["gke-node", var.cluster_name]
  }
}

# ── Database ────────────────────────────────────────────────────────────────

resource "google_sql_database_instance" "postgres" {
  name             = var.sql_instance_name
  database_version = var.database_version
  region           = var.region
  project          = var.project_id

  settings {
    tier      = var.sql_tier
    edition   = "ENTERPRISE"
    disk_size = 20
    disk_type = "PD_SSD"
    # The disk grows on its own. A ticketing database that runs out of space
    # mid-sale takes the ledger with it, and nobody watches a graph at 06:00.
    disk_autoresize = true

    ip_configuration {
      # No public IP. Everything that talks to this is in the VPC.
      ipv4_enabled                                  = false
      private_network                               = google_compute_network.vpc.id
      enable_private_path_for_google_cloud_services = true
    }

    backup_configuration {
      enabled = true
      # 01:00 UTC is 02:00 in Brazzaville — after the last coach and before
      # the nightly worker pass, so a backup and a horizon extension are not
      # competing for the same disk.
      start_time                     = "01:00"
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 14
      }
    }

    maintenance_window {
      # Sunday 03:00 UTC. There is no hour with nobody travelling, but this is
      # the quietest one.
      day  = 7
      hour = 3
    }

    insights_config {
      query_insights_enabled = true
    }

    database_flags {
      # Every migration is one transaction and several take an ACCESS EXCLUSIVE
      # lock. Failing after ten seconds is better than queueing every request
      # behind a lock nobody is watching.
      name  = "lock_timeout"
      value = "10000"
    }
  }

  depends_on          = [google_service_networking_connection.private_vpc]
  deletion_protection = var.deletion_protection
}

resource "google_sql_database" "billetenligne" {
  name     = var.database_name
  instance = google_sql_database_instance.postgres.name
  project  = var.project_id
}

# The owner, and the only user Terraform creates.
#
# `bel_api` is deliberately absent — see `sql_owner_user` in variables.tf. It
# is created by migration 0005 as NOLOGIN and NOINHERIT and given a password by
# hand afterwards; a Cloud SQL user of that name created here would be an
# inheriting role, the migration would skip it, and row-level security would
# quietly stop applying. `verify.sql` asserts against exactly that.
resource "google_sql_user" "owner" {
  name     = var.sql_owner_user
  instance = google_sql_database_instance.postgres.name
  password = var.sql_owner_password
  project  = var.project_id
}
