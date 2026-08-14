output "registry" {
  description = "BEL_REGISTRY for tool/images.sh and infra/k8s/deploy.sh."
  value       = module.bel.registry
}

output "ingress_ip" {
  description = "The A record for blt.cg, console.blt.cg and admin.blt.cg."
  value       = module.bel.ingress_ip
}

output "sql_private_ip" {
  value = module.bel.sql_private_ip
}

output "cluster" {
  value = "${module.bel.cluster_name} (${module.bel.cluster_location})"
}

output "next_steps" {
  description = "What Terraform cannot do, in the order it has to be done."
  value       = <<-EOT
    1. gcloud container clusters get-credentials ${module.bel.cluster_name} \
         --location ${module.bel.cluster_location}

    2. KEDA, which has no Terraform field and without which the worker
       never runs — a ScaledJob on a cluster without it is accepted and
       ignored:
         gcloud container clusters update ${module.bel.cluster_name} \
           --location ${module.bel.cluster_location} --enable-keda

    3. Point blt.cg, console.blt.cg and admin.blt.cg at ${module.bel.ingress_ip}.
       The managed certificate provisions itself once they resolve, and not
       before.

    4. Create the secret. See infra/k8s/secrets.example.yaml — it names every
       key and holds no values. The API refuses to start without
       TICKETS__SIGNINGSEED.

    5. Deploy, which applies the migrations first:
         BEL_REGISTRY=${module.bel.registry} BEL_API_URL=https://blt.cg \
           ./infra/k8s/deploy.sh

    6. Give the application role a password — as the owner, and only after the
       migrations have created it NOLOGIN and NOINHERIT:
         ALTER ROLE bel_api LOGIN PASSWORD '...';
         GRANT bel_public, bel_app, bel_admin, bel_identity TO bel_api;
       Terraform deliberately does not create this user: a Cloud SQL user of
       that name would inherit, and row-level security would stop applying.
  EOT
}
