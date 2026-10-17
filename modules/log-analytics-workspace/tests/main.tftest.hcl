# A mocked provider: no Azure, no credentials. The workspace gets a valid Azure ID so
# that runs with command = apply can check the module's output.
mock_provider "azurerm" {
  mock_resource "azurerm_log_analytics_workspace" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/log-test"
    }
  }
}

variables {
  name                = "log-test"
  resource_group_name = "rg-test"
  location            = "westeurope"
}

run "uses_pay_per_gb_sku" {
  command = plan

  assert {
    condition     = azurerm_log_analytics_workspace.this.sku == "PerGB2018"
    error_message = "The workspace must use the PerGB2018 SKU: the module fixes it for every environment."
  }
}

run "keeps_logs_for_30_days_by_default" {
  command = plan

  assert {
    condition     = azurerm_log_analytics_workspace.this.retention_in_days == 30
    error_message = "Without an explicit retention, logs must be kept for 30 days as the variable default promises."
  }
}

run "keeps_logs_for_the_requested_retention" {
  command = plan

  variables {
    retention_in_days = 90
  }

  assert {
    condition     = azurerm_log_analytics_workspace.this.retention_in_days == 90
    error_message = "A caller-chosen retention must replace the 30-day default, or logs could be deleted too early."
  }
}

run "outputs_the_workspace_id" {
  command = apply

  assert {
    condition     = output.id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/log-test"
    error_message = "The id output must be the ID of the workspace this module creates, so diagnostic settings send logs to it."
  }
}
