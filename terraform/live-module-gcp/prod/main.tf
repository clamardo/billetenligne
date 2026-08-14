# Production, in the Republic of the Congo's market, on GCP.
#
#   cd terraform/live-module-gcp/prod
#   terraform init && terraform plan && terraform apply
#
# The state bucket is created **out of band**, by hand, before this runs.
# Terraform must never manage the bucket that holds its own state: destroying
# it is then a bootstrapping problem rather than a mistake you can undo.
#
#   gcloud storage buckets create gs://bel-tf-prod \
#     --project=<project> --location=europe-west1 \
#     --uniform-bucket-level-access --public-access-prevention
#   gcloud storage buckets update gs://bel-tf-prod --versioning
terraform {
  required_version = ">= 1.6.0"

  backend "gcs" {
    bucket = "bel-tf-prod"
    prefix = "prod"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

# Credentials and project ids live in a gitignored JSON file rather than in
# variables typed at a prompt or committed here — one file, one place to
# rotate, and nothing secret in the repository.
locals {
  credentials = jsondecode(file("${path.module}/../../credentials-prod.json"))
}

provider "google" {
  project = local.credentials.project_id
  region  = var.region
}

module "bel" {
  source = "../../gcp-module"

  project_id  = local.credentials.project_id
  region      = var.region
  zone        = var.zone
  environment = "prod"

  cluster_name      = "bel-eu-prod-gke"
  sql_instance_name = "bel-eu-prod-pg"

  sql_owner_password = local.credentials.sql_owner_password

  # Not spot. A reclaim happens when Google needs the capacity, which is the
  # middle of a European working day and the middle of the Congolese selling
  # day.
  use_spot_nodes = false

  min_node_count = 2
  max_node_count = 3

  deletion_protection = true

  common_labels = {
    app         = "billetenligne"
    environment = "prod"
    managed-by  = "terraform"
  }
}
