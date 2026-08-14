output "storage_account" {
  description = "STORAGE__ACCOUNT."
  value       = azurerm_storage_account.bel.name
}

output "storage_container" {
  description = "STORAGE__CONTAINER."
  value       = azurerm_storage_container.assets.name
}

output "storage_endpoint" {
  description = "STORAGE__ENDPOINT."
  value       = azurerm_storage_account.bel.primary_blob_endpoint
}

output "storage_key" {
  description = "STORAGE__KEY. Rotate it in the portal and update the Kubernetes secret; nothing caches it beyond a process lifetime."
  value       = azurerm_storage_account.bel.primary_access_key
  sensitive   = true
}

output "communication_connection_string" {
  description = "COMMS__CONNECTIONSTRING."
  value       = azurerm_communication_service.bel.primary_connection_string
  sensitive   = true
}

output "email_from" {
  description = "COMMS__EMAILFROM, until a custom domain is verified. `donotreply@<guid>.azurecomm.net` is not an address to put on a poster, and it delivers."
  value       = "donotreply@${azurerm_email_communication_service_domain.managed.from_sender_domain}"
}
