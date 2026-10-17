mock_provider "azurerm" {}

variables {
  name                = "sttptest001"
  resource_group_name = "rg-test"
  location            = "westeurope"
  containers          = ["raw", "curated"]
}

run "account_is_locked_down_by_default" {
  command = plan

  assert {
    condition     = azurerm_storage_account.this.min_tls_version == "TLS1_2"
    error_message = "The account must require TLS 1.2."
  }

  assert {
    condition     = azurerm_storage_account.this.https_traffic_only_enabled == true
    error_message = "The account must refuse plain HTTP: data and tokens would travel unencrypted."
  }

  assert {
    condition     = azurerm_storage_account.this.allow_nested_items_to_be_public == false
    error_message = "Public blob access must be off."
  }

  assert {
    condition     = azurerm_storage_account.this.shared_access_key_enabled == false
    error_message = "Shared key access must be off, so that only Entra ID identities can reach the data."
  }

  assert {
    condition     = azurerm_storage_account_network_rules.this.default_action == "Deny"
    error_message = "Network access must be denied by default."
  }
}

run "only_azure_services_bypass_the_network_rules" {
  command = plan

  assert {
    condition     = azurerm_storage_account_network_rules.this.bypass == toset(["AzureServices"])
    error_message = "Only trusted Azure services may bypass the network rules; logging or metrics bypasses widen access."
  }
}

run "allowed_subnets_reach_the_network_rules" {
  command = plan

  variables {
    allowed_subnet_ids = [
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-data",
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-compute",
    ]
  }

  assert {
    condition = azurerm_storage_account_network_rules.this.virtual_network_subnet_ids == toset([
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-data",
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-compute",
    ])
    error_message = "Exactly the allowed subnets must be able to reach the account; everything else is denied."
  }
}

run "no_subnet_is_allowed_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_storage_account_network_rules.this.virtual_network_subnet_ids) == 0
    error_message = "Without allowed subnets no virtual network may reach the account."
  }
}

run "deleted_blobs_are_kept_for_seven_days" {
  command = plan

  assert {
    condition     = azurerm_storage_account.this.blob_properties[0].delete_retention_policy[0].days == 7
    error_message = "Deleted blobs must be recoverable for 7 days, so that a mistake does not lose data."
  }
}

run "defaults_to_locally_redundant_storagev2_without_namespace" {
  command = plan

  assert {
    condition     = azurerm_storage_account.this.account_kind == "StorageV2"
    error_message = "The account must be a general-purpose v2 account."
  }

  assert {
    condition     = azurerm_storage_account.this.account_replication_type == "LRS"
    error_message = "Replication must default to LRS, as the variable documents."
  }

  assert {
    condition     = azurerm_storage_account.this.is_hns_enabled == false
    error_message = "The hierarchical namespace must be off unless a data lake is requested."
  }
}

run "data_lake_turns_on_hierarchical_namespace" {
  command = plan

  variables {
    is_data_lake = true
  }

  assert {
    condition     = azurerm_storage_account.this.is_hns_enabled == true
    error_message = "A data lake account must have the hierarchical namespace turned on."
  }
}

run "creates_one_container_per_name" {
  command = plan

  assert {
    condition     = length(azurerm_storage_container.this) == 2
    error_message = "Expected one container for each name."
  }

  assert {
    condition     = toset(keys(azurerm_storage_container.this)) == toset(["raw", "curated"])
    error_message = "Containers must be keyed and named by the names in var.containers."
  }
}

run "containers_are_private" {
  command = plan

  assert {
    condition     = alltrue([for container in azurerm_storage_container.this : container.container_access_type == "private"])
    error_message = "Every container must be private: anonymous read access would expose the data."
  }
}

run "creates_no_container_without_names" {
  command = plan

  variables {
    containers = []
  }

  assert {
    condition     = length(azurerm_storage_container.this) == 0
    error_message = "No container names must mean no containers."
  }
}

run "containers_and_network_rules_use_this_account" {
  command = plan

  override_resource {
    target          = azurerm_storage_account.this
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/sttptest001"
    }
  }

  assert {
    condition     = alltrue([for container in azurerm_storage_container.this : container.storage_account_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/sttptest001"])
    error_message = "Containers must be created in the account this module creates."
  }

  assert {
    condition     = azurerm_storage_account_network_rules.this.storage_account_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/sttptest001"
    error_message = "The network rules must protect the account this module creates."
  }
}

run "accepts_name_of_24_characters" {
  command = plan

  variables {
    name = "st0123456789abcdefghijkl"
  }

  assert {
    condition     = azurerm_storage_account.this.name == "st0123456789abcdefghijkl"
    error_message = "A 24-character lowercase name is valid and must be accepted."
  }
}

run "rejects_invalid_name" {
  command = plan

  variables {
    name = "Invalid-Name"
  }

  expect_failures = [var.name]
}

run "rejects_name_shorter_than_3_characters" {
  command = plan

  variables {
    name = "st"
  }

  expect_failures = [var.name]
}

run "rejects_name_longer_than_24_characters" {
  command = plan

  variables {
    name = "st0123456789abcdefghijklm"
  }

  expect_failures = [var.name]
}
