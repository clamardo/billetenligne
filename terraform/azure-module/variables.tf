variable "resource_group_name" {
  type = string
}

variable "location" {
  description = "Where the storage account lives. Communication Services is global and takes a data-residency choice instead."
  type        = string
  default     = "westeurope"
}

variable "environment" {
  type = string
}

variable "storage_account_name" {
  description = "Globally unique, 3-24 characters, lower case letters and digits only. Azure's rule, not ours."
  type        = string
}

variable "communication_name" {
  type = string
}

variable "data_location" {
  description = <<-EOT
    Where Communication Services keeps message data.

    `Africa` is not one of the values Azure accepts, so this is `Europe` — the
    same trade the GCP region makes, and worth saying out loud rather than
    leaving as a default nobody chose.
  EOT
  type        = string
  default     = "Europe"
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
