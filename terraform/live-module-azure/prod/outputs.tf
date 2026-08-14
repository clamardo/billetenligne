# The five values that go into the Kubernetes secret. Three are sensitive and
# print as `<sensitive>` until asked for by name:
#
#   terraform output -raw storage_key
#   terraform output -raw communication_connection_string
output "storage_account" { value = module.bel.storage_account }
output "storage_container" { value = module.bel.storage_container }
output "storage_endpoint" { value = module.bel.storage_endpoint }
output "email_from" { value = module.bel.email_from }

output "storage_key" {
  value     = module.bel.storage_key
  sensitive = true
}

output "communication_connection_string" {
  value     = module.bel.communication_connection_string
  sensitive = true
}
