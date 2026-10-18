variable "name" {
  description = "Function app name."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that holds the function app."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "storage_account_name" {
  description = "Storage account the function app uses for its runtime."
  type        = string
}

variable "storage_account_id" {
  description = "ID of that storage account."
  type        = string
}

variable "python_version" {
  description = "Python version of the runtime."
  type        = string
  default     = "3.12"
}

variable "sku_name" {
  description = "Elastic Premium plan of the function app: EP1, EP2 or EP3."
  type        = string
  default     = "EP1"

  validation {
    condition     = contains(["EP1", "EP2", "EP3"], var.sku_name)
    error_message = "sku_name must be EP1, EP2 or EP3 (an Elastic Premium plan)."
  }
}

variable "ftps_state" {
  description = "FTP access for deployments: Disabled (no FTP) or FtpsOnly (encrypted FTP only)."
  type        = string
  default     = "Disabled"

  validation {
    condition     = contains(["Disabled", "FtpsOnly"], var.ftps_state)
    error_message = "ftps_state must be Disabled or FtpsOnly: plain FTP (AllAllowed) sends credentials unencrypted."
  }
}

variable "public_network_access_enabled" {
  description = "Allow access to the app from the public internet."
  type        = bool
  default     = true
}

variable "app_settings" {
  description = "Application settings."
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags for all resources."
  type        = map(string)
  default     = {}
}
