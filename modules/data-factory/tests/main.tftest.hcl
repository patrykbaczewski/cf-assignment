# A mocked provider: no Azure, no credentials. The factory gets a valid Azure ID so that
# the linked services and the diagnostic setting accept it during apply.
mock_provider "azurerm" {
  mock_resource "azurerm_data_factory" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.DataFactory/factories/adf-test"
    }
  }
}

# Realistic values: the mocked provider still checks formats (names, IDs, URLs).
variables {
  name                       = "adf-test"
  resource_group_name        = "rg-test"
  location                   = "westeurope"
  log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/log-test"
  linked_storage_accounts = {
    raw     = "https://stlakeraw001.dfs.core.windows.net/"
    curated = "https://stlakecur001.dfs.core.windows.net/"
  }
}

run "factory_has_system_assigned_identity" {
  command = plan

  assert {
    condition     = azurerm_data_factory.this.identity[0].type == "SystemAssigned"
    error_message = "The factory must have a system-assigned identity: linked services authenticate with it instead of stored keys."
  }
}

run "factory_can_be_closed_to_public_network" {
  command = plan

  variables {
    public_network_enabled = false
  }

  assert {
    condition     = azurerm_data_factory.this.public_network_enabled == false
    error_message = "Setting public_network_enabled to false must close the factory to the public internet."
  }
}

run "creates_one_linked_service_per_storage_account" {
  command = plan

  assert {
    condition     = length(azurerm_data_factory_linked_service_data_lake_storage_gen2.this) == 2
    error_message = "Expected one linked service for each entry in var.linked_storage_accounts."
  }

  assert {
    condition     = azurerm_data_factory_linked_service_data_lake_storage_gen2.this["raw"].name == "ls-raw"
    error_message = "A linked service must be named ls-<key> after its key in var.linked_storage_accounts."
  }

  assert {
    condition     = azurerm_data_factory_linked_service_data_lake_storage_gen2.this["curated"].url == "https://stlakecur001.dfs.core.windows.net/"
    error_message = "A linked service must point at the DFS endpoint given for its key."
  }
}

run "linked_services_use_managed_identity" {
  command = plan

  assert {
    condition     = alltrue([for ls in azurerm_data_factory_linked_service_data_lake_storage_gen2.this : ls.use_managed_identity == true])
    error_message = "Linked services must authenticate with the factory's managed identity, not with account keys or SAS tokens."
  }
}

run "creates_no_linked_service_without_accounts" {
  command = plan

  variables {
    linked_storage_accounts = {}
  }

  assert {
    condition     = length(azurerm_data_factory_linked_service_data_lake_storage_gen2.this) == 0
    error_message = "No storage accounts must mean no linked services."
  }
}

run "diagnostics_send_pipeline_and_activity_runs" {
  command = plan

  assert {
    condition     = azurerm_monitor_diagnostic_setting.this.name == "diag-adf-test"
    error_message = "The diagnostic setting must be named diag-<factory name>."
  }

  assert {
    condition     = toset([for log in azurerm_monitor_diagnostic_setting.this.enabled_log : log.category]) == toset(["PipelineRuns", "ActivityRuns"])
    error_message = "Pipeline and activity runs must be logged, so failed runs can be investigated."
  }

  assert {
    condition     = azurerm_monitor_diagnostic_setting.this.log_analytics_workspace_id == var.log_analytics_workspace_id
    error_message = "Diagnostic logs must go to the given Log Analytics workspace."
  }
}

# With command = apply the factory ID from mock_provider above is known.
run "linked_services_and_diagnostics_target_this_factory" {
  command = apply

  assert {
    condition     = alltrue([for ls in azurerm_data_factory_linked_service_data_lake_storage_gen2.this : ls.data_factory_id == azurerm_data_factory.this.id])
    error_message = "Linked services must belong to the factory this module creates."
  }

  assert {
    condition     = azurerm_monitor_diagnostic_setting.this.target_resource_id == azurerm_data_factory.this.id
    error_message = "Diagnostic logs must be collected from the factory this module creates."
  }

  assert {
    condition     = output.id == azurerm_data_factory.this.id
    error_message = "The id output must be the ID of the factory."
  }

  assert {
    condition     = output.principal_id == azurerm_data_factory.this.identity[0].principal_id
    error_message = "The principal_id output must be the factory's managed identity, so callers can grant it data lake roles."
  }
}
