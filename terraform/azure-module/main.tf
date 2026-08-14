# The Azure half: the object store and the messages.
#
# **Why two clouds.** The cluster and the database are on GCP because that is
# where the account and the billing are. Email and SMS are Azure
# Communication Services (ADR-0019), and the object store is Azure Blob
# because the storage adapter was written against it and the local stack runs
# Azurite. Splitting is a real cost — two consoles, two bills, two identity
# systems — and it is smaller than rewriting a signing implementation that is
# thirteen lines in a fixed order and answers 403 with no hint about which one
# was wrong.

resource "azurerm_resource_group" "bel" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.common_tags
}

# ── The object store ────────────────────────────────────────────────────────
#
# KYB documents, operator logos, ticket PDFs. One container, private, and the
# reads that need to be public are signed for a short window rather than made
# public — a KYB document is somebody's identity card.

resource "azurerm_storage_account" "bel" {
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.bel.name
  location                 = azurerm_resource_group.bel.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  https_traffic_only_enabled = true
  min_tls_version            = "TLS1_2"
  # Nothing in this account is ever anonymously readable. The one thing that
  # looks like it wants to be — an operator's logo on a public storefront — is
  # served through a signed URL with an expiry, because the same container
  # holds the identity documents that got that operator approved.
  allow_nested_items_to_be_public = false

  blob_properties {
    delete_retention_policy {
      days = 30
    }
  }

  tags = var.common_tags
}

resource "azurerm_storage_container" "assets" {
  name                  = "bel-assets"
  storage_account_id    = azurerm_storage_account.bel.id
  container_access_type = "private"
}

# ── The messages ────────────────────────────────────────────────────────────

resource "azurerm_communication_service" "bel" {
  name                = var.communication_name
  resource_group_name = azurerm_resource_group.bel.name
  data_location       = var.data_location
  tags                = var.common_tags
}

resource "azurerm_email_communication_service" "bel" {
  name                = "${var.communication_name}-email"
  resource_group_name = azurerm_resource_group.bel.name
  data_location       = var.data_location
  tags                = var.common_tags
}

# The Azure-managed domain, which sends from a name nobody would put on a
# poster (`donotreply@<guid>.azurecomm.net`) and needs no DNS at all. It is
# what makes the whole delivery path exercisable before a domain is verified —
# and it is deliberately the *starting* state rather than the end one: a
# custom domain is a DNS change plus a verification wait, and neither is
# something to discover on launch day.
resource "azurerm_email_communication_service_domain" "managed" {
  name              = "AzureManagedDomain"
  email_service_id  = azurerm_email_communication_service.bel.id
  domain_management = "AzureManaged"
  tags              = var.common_tags
}

resource "azurerm_communication_service_email_domain_association" "managed" {
  communication_service_id = azurerm_communication_service.bel.id
  email_service_domain_id  = azurerm_email_communication_service_domain.managed.id
}

# **No phone number is bought here.** SMS in the Republic of the Congo needs a
# number Azure can actually originate from, and that is a purchase with a
# regulatory form attached rather than a resource. Until one exists,
# `COMMS__SMSFROM` stays empty and the API answers 503 for the phone channel
# by name — which is better than accepting a request and leaving somebody at a
# station waiting for an SMS that is never coming (ADR-0019).
