output "cluster_name" {
  value = google_container_cluster.primary.name
}

output "cluster_location" {
  value = google_container_cluster.primary.location
}

output "registry" {
  description = "What BEL_REGISTRY should be set to."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.docker.repository_id}"
}

output "ingress_ip" {
  description = "Point blt.cg, console.blt.cg and admin.blt.cg here. The managed certificate provisions itself once they resolve, and not before."
  value       = google_compute_global_address.ingress.address
}

output "sql_private_ip" {
  description = "The host half of DATABASE_URL and MIGRATE_DATABASE_URL."
  value       = google_sql_database_instance.postgres.private_ip_address
}

output "sql_connection_name" {
  value = google_sql_database_instance.postgres.connection_name
}

output "node_service_account" {
  value = google_service_account.nodes.email
}

output "workload_service_account" {
  description = "What the `iam.gke.io/gcp-service-account` annotation on the `bel` service account resolves to, and what BEL_PROJECT produces."
  value       = google_service_account.workload.email
}
