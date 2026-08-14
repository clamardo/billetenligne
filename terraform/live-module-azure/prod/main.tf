# The Azure half of production: the object store and the messages.
#
#   cd terraform/live-module-azure/prod
#   terraform init && terraform plan && terraform apply
#
# State lives in an Azure storage account created out of band, for the same
# reason the GCP state bucket is: Terraform must never manage the thing that
# holds its own state.
terraform {
  required_version = ">= 1.6.0"

  backend "azurerm" {
    resource_group_name  = "bel-tfstate"
    storage_account_name = "beltfstateprod"
    container_name       = "tfstate"
    key                  = "prod.tfstate"
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

locals {
  credentials = jsondecode(file("${path.module}/../../credentials-prod.json"))
}

provider "azurerm" {
  features {}
  subscription_id = local.credentials.azure_subscription_id
}

module "bel" {
  source = "../../azure-module"

  resource_group_name  = "bel-prod"
  location             = var.location
  environment          = "prod"
  storage_account_name = local.credentials.azure_storage_account_name
  communication_name   = "bel-prod-comms"

  common_tags = {
    app         = "billetenligne"
    environment = "prod"
    managed-by  = "terraform"
  }
}
