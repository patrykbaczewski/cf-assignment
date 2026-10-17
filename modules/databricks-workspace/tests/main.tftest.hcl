# A mocked provider: no Azure, no credentials. Tests check the module's plan only.
mock_provider "azurerm" {}

variables {
  name                = "dbw-test"
  resource_group_name = "rg-test"
  location            = "westeurope"
}

run "clusters_get_no_public_ip" {
  command = plan

  assert {
    condition     = azurerm_databricks_workspace.this.custom_parameters[0].no_public_ip == true
    error_message = "Cluster nodes must have no public IP (secure cluster connectivity), so they cannot be reached from the internet."
  }
}

run "defaults_to_premium_sku" {
  command = plan

  assert {
    condition     = azurerm_databricks_workspace.this.sku == "premium"
    error_message = "Without an explicit sku the workspace must use the premium tier, as the variable documents."
  }
}

run "accepts_standard_sku" {
  command = plan

  variables {
    sku = "standard"
  }

  assert {
    condition     = azurerm_databricks_workspace.this.sku == "standard"
    error_message = "The standard tier is an allowed choice and must reach the workspace."
  }
}

run "rejects_unknown_sku" {
  command = plan

  variables {
    sku = "trial"
  }

  expect_failures = [var.sku]
}

run "managed_resource_group_name_follows_pattern" {
  command = plan

  assert {
    condition     = azurerm_databricks_workspace.this.managed_resource_group_name == "rg-test-dbw-test-managed"
    error_message = "The managed resource group must be named <resource group>-<workspace>-managed so it can be traced to its workspace."
  }
}

run "public_network_access_can_be_turned_off" {
  command = plan

  variables {
    public_network_access_enabled = false
  }

  assert {
    condition     = azurerm_databricks_workspace.this.public_network_access_enabled == false
    error_message = "When public network access is turned off, the workspace must not be reachable from the public internet."
  }
}
