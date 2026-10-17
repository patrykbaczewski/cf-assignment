# A mocked provider: no Azure, no credentials.
mock_provider "azurerm" {}

# The module runs scripts/build-info.sh through data "external". Without this override
# the script would run during every test.
override_data {
  target = data.external.build_info
  values = {
    result = { revision = "abc1234" }
  }
}

variables {
  name                 = "func-test"
  resource_group_name  = "rg-test"
  location             = "westeurope"
  storage_account_name = "stfunctest001"
  storage_account_id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/stfunctest001"
}

run "app_enforces_https_and_tls_1_2" {
  command = plan

  assert {
    condition     = azurerm_linux_function_app.this.https_only == true
    error_message = "The function app must refuse plain HTTP."
  }

  assert {
    condition     = azurerm_linux_function_app.this.site_config[0].minimum_tls_version == "1.2"
    error_message = "The function app must require TLS 1.2 or newer: older TLS versions are insecure."
  }
}

run "app_uses_managed_identity_for_storage" {
  command = plan

  assert {
    condition     = azurerm_linux_function_app.this.identity[0].type == "SystemAssigned"
    error_message = "The function app must have a system-assigned identity to reach its storage without keys."
  }

  assert {
    condition     = azurerm_linux_function_app.this.storage_uses_managed_identity == true
    error_message = "The runtime storage must be reached with the managed identity, not with an access key."
  }
}

run "plan_defaults_to_ep1_linux" {
  command = plan

  assert {
    condition     = azurerm_service_plan.this.sku_name == "EP1"
    error_message = "Without sku_name the plan must stay on EP1, the size used before sku_name existed."
  }

  assert {
    condition     = azurerm_service_plan.this.os_type == "Linux"
    error_message = "The plan must be Linux: the module creates a Linux function app."
  }

  assert {
    condition     = azurerm_service_plan.this.name == "asp-func-test"
    error_message = "The service plan must be named asp-<name>."
  }
}

run "accepts_ep3_sku" {
  command = plan

  variables {
    sku_name = "EP3"
  }

  assert {
    condition     = azurerm_service_plan.this.sku_name == "EP3"
    error_message = "An allowed Elastic Premium SKU must reach the service plan."
  }
}

run "rejects_consumption_sku" {
  command = plan

  variables {
    sku_name = "Y1"
  }

  expect_failures = [var.sku_name]
}

run "rejects_lowercase_sku" {
  command = plan

  variables {
    sku_name = "ep2"
  }

  expect_failures = [var.sku_name]
}

run "app_settings_keep_caller_values_and_add_build_revision" {
  command = plan

  variables {
    app_settings = {
      FUNCTIONS_WORKER_RUNTIME = "python"
    }
  }

  assert {
    condition     = azurerm_linux_function_app.this.app_settings["FUNCTIONS_WORKER_RUNTIME"] == "python"
    error_message = "Caller app settings must be kept."
  }

  assert {
    condition     = azurerm_linux_function_app.this.app_settings["BUILD_REVISION"] == "abc1234"
    error_message = "BUILD_REVISION must come from the build-info source."
  }
}

run "app_runs_on_its_own_service_plan" {
  command = plan

  override_resource {
    target          = azurerm_service_plan.this
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Web/serverFarms/asp-func-test"
    }
  }

  assert {
    condition     = azurerm_linux_function_app.this.service_plan_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Web/serverFarms/asp-func-test"
    error_message = "The function app must run on the service plan this module creates."
  }
}

run "storage_role_is_scoped_to_the_runtime_storage_account" {
  command = plan

  assert {
    condition     = azurerm_role_assignment.runtime_storage.scope == var.storage_account_id
    error_message = "The storage role must be scoped to the runtime storage account, not a wider scope."
  }
}
