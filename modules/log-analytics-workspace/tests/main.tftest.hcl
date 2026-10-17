mock_provider "azurerm" {
  mock_resource "azurerm_log_analytics_workspace" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/law-test"
    }
  }
}

variables {
  name                = "law-test"
  resource_group_name = "rg-test"
  location            = "westeurope"
}

run "creates_workspace_with_correct_name" {
  command = plan

  assert {
    condition     = azurerm_log_analytics_workspace.this.name == "law-test"
    error_message = "Workspace name must match the input variable."
  }
}

run "creates_workspace_in_correct_resource_group" {
  command = plan

  assert {
    condition     = azurerm_log_analytics_workspace.this.resource_group_name == "rg-test"
    error_message = "Workspace must be created in the specified resource group."
  }
}

run "creates_workspace_in_correct_location" {
  command = plan

  assert {
    condition     = azurerm_log_analytics_workspace.this.location == "westeurope"
    error_message = "Workspace must be created in the specified location."
  }
}

run "sku_is_always_pergb2018" {
  command = plan

  assert {
    condition     = azurerm_log_analytics_workspace.this.sku == "PerGB2018"
    error_message = "Workspace SKU must be set to PerGB2018 for cost control."
  }
}

run "retention_in_days_defaults_to_30" {
  command = plan

  assert {
    condition     = azurerm_log_analytics_workspace.this.retention_in_days == 30
    error_message = "Retention in days must default to 30 days."
  }
}

run "retention_in_days_can_be_customized" {
  command = plan

  variables {
    retention_in_days = 90
  }

  assert {
    condition     = azurerm_log_analytics_workspace.this.retention_in_days == 90
    error_message = "Retention in days must be customizable through the variable."
  }
}

run "tags_default_to_empty" {
  command = plan

  assert {
    condition     = try(length(azurerm_log_analytics_workspace.this.tags), 0) == 0 || azurerm_log_analytics_workspace.this.tags == null
    error_message = "Tags must default to an empty map or null when not provided."
  }
}

run "tags_can_be_provided" {
  command = plan

  variables {
    tags = {
      Environment = "test"
      Owner       = "platform"
    }
  }

  assert {
    condition     = azurerm_log_analytics_workspace.this.tags["Environment"] == "test"
    error_message = "Tags must be applied to the workspace."
  }

  assert {
    condition     = azurerm_log_analytics_workspace.this.tags["Owner"] == "platform"
    error_message = "Tags must be applied to the workspace."
  }
}

run "workspace_id_is_exposed_in_output" {
  command = apply

  assert {
    condition     = output.id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/law-test"
    error_message = "The workspace ID must be exposed in the module output."
  }
}
