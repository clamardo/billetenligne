# Terraform

Two clouds, one product.

`gcp-module` + `live-module-gcp/prod` — the VPC, the private GKE cluster with
Cloud NAT, Artifact Registry, Cloud SQL for Postgres on a private address, and
the static IP the posters point at.

`azure-module` + `live-module-azure/prod` — the Blob container that holds KYB
documents, operator logos and ticket PDFs, and the Communication Services
resource that sends the email.

**Why the split is real and not historical.** The cluster and the database are
on GCP because that is where the account and the billing are. The messages are
Azure Communication Services (ADR-0019) and the object store is Azure Blob
because the storage adapter was written against it, signs with Shared Key, and
is exercised in CI against Azurite. Two consoles and two bills is a cost; it is
smaller than rewriting an implementation whose thirteen signing steps have to
be in one order and which answers 403 with no hint about which one was wrong.

## Before anything

State buckets are created **by hand**, out of band. Terraform must never
manage the thing that holds its own state — destroying it is then a
bootstrapping problem rather than a mistake you can undo.

```
gcloud storage buckets create gs://bel-tf-prod \
  --project=<project> --location=europe-west1 \
  --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update gs://bel-tf-prod --versioning
```

Then the credentials file, which is gitignored and is the single place a
project id or a database password is written down:

```
cp terraform/credentials-prod.sample.json terraform/credentials-prod.json
```

## Then

```
cd terraform/live-module-gcp/prod   && terraform init && terraform apply
cd terraform/live-module-azure/prod && terraform init && terraform apply
```

`terraform output next_steps` on the GCP side prints the rest in order. Three
of those steps are things Terraform cannot do, and each of them fails quietly
if skipped:

**KEDA has no Terraform field.** It is a `gcloud container clusters update
--enable-keda`. A ScaledJob applied to a cluster without it is accepted by the
API server as an unknown kind and never runs — the quietest failure in this
whole deployment, and the one that would be found by a traveller whose payment
was never polled.

**DNS.** The managed certificate provisions itself once `blt.cg`,
`console.blt.cg` and `admin.blt.cg` resolve to the ingress address, and not
before. A certificate stuck in `Provisioning` is almost always DNS.

**The database's application role.** Terraform creates the *owner* and
deliberately does not create `bel_api`. That role is created by migration 0005
as NOLOGIN and NOINHERIT, and given a password by hand afterwards:

```sql
ALTER ROLE bel_api LOGIN PASSWORD '…';
GRANT bel_public, bel_app, bel_admin, bel_identity TO bel_api;
```

A Cloud SQL user of that name created by Terraform would be an **inheriting**
role; the migration's `IF NOT EXISTS` would politely skip it; and every request
would then run with the union of the public, tenant and platform privileges,
which is row-level security switched off without a line of code changing.
`infra/migrations/verify.sql` asserts against exactly that, and CI runs it.

## What is not here

**No staging environment.** One live module, `prod`. A staging copy is real
money for a product with no operator signed yet, and the honest way to add one
is a second directory that differs in three variables — not a `count` on
everything in the module.

**No CI that runs `terraform apply`.** A pipeline with credentials to rebuild
the cluster is a pipeline that can destroy it, and this is applied from a
workstation by somebody who read the plan.

**Nothing has been applied.** These files describe what the deployment should
be; no cluster exists, no plan has been run against a real project, and every
number in them — the machine type, the tier, the node count — is a starting
guess rather than something a load test produced.
