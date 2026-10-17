# Example: tests for a module

The module below is made up for this example, so it does not exist in the repository.
The test file was run with the same Terraform version and sandbox as the real tests,
and all seven runs pass.

## The module (shortened)

```hcl
variable "name" {
  type = string
  validation {
    condition     = can(regex("^app-[a-z0-9-]{3,40}$", var.name))
    error_message = "The name must start with app-."
  }
}

variable "sku_name" {
  type    = string
  default = "P1v3"
  validation {
    condition     = contains(["P1v3", "P2v3"], var.sku_name)
    error_message = "The SKU must be P1v3 or P2v3."
  }
}

variable "readers" {
  description = "Object IDs that get read access to the app, by a short key."
  type        = map(string)
  default     = {}
}

data "external" "version" {
  program = ["sh", "${path.module}/scripts/version.sh"]
}

resource "azurerm_service_plan" "this" { ... sku_name = var.sku_name }

resource "azurerm_linux_web_app" "this" {
  service_plan_id               = azurerm_service_plan.this.id
  https_only                    = true
  public_network_access_enabled = false
  site_config {
    minimum_tls_version = "1.2"
    ftps_state          = "Disabled"
  }
  app_settings = {
    APP_VERSION = data.external.version.result.version
  }
  ...
}

resource "azurerm_role_assignment" "reader" {
  for_each             = var.readers
  scope                = azurerm_linux_web_app.this.id
  role_definition_name = "Reader"
  principal_id         = each.value
}
```

## The test file: `modules/web-app/tests/main.tftest.hcl`

```hcl
# A mocked provider: no Azure, no credentials. Computed attributes such as `id` get
# random strings, and resources that take an ID as input reject those during apply.
# So every resource that other resources refer to by ID gets a valid Azure ID here.
mock_provider "azurerm" {
  mock_resource "azurerm_service_plan" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Web/serverFarms/asp-app-test"
    }
  }

  mock_resource "azurerm_linux_web_app" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Web/sites/app-test"
    }
  }
}

# The module runs a local script through data "external". Without this override the
# script would run during every test.
override_data {
  target = data.external.version
  values = {
    result = { version = "1.2.3" }
  }
}

# Realistic values: the mocked provider still checks formats (names, UUIDs, IDs).
variables {
  name                = "app-test"
  resource_group_name = "rg-test"
  location            = "westeurope"
  readers = {
    ops   = "11111111-1111-1111-1111-111111111111"
    audit = "22222222-2222-2222-2222-222222222222"
  }
}

run "app_is_private_and_https_only" {
  command = plan

  assert {
    condition     = azurerm_linux_web_app.this.https_only == true
    error_message = "The app must refuse plain HTTP."
  }

  assert {
    condition     = azurerm_linux_web_app.this.public_network_access_enabled == false
    error_message = "The app must not be reachable from the public internet."
  }

  assert {
    condition     = azurerm_linux_web_app.this.site_config[0].ftps_state == "Disabled"
    error_message = "FTP deployment must be off: it sends credentials in plain text."
  }
}

run "app_settings_carry_the_build_version" {
  command = plan

  assert {
    condition     = azurerm_linux_web_app.this.app_settings["APP_VERSION"] == "1.2.3"
    error_message = "APP_VERSION must come from the build-info source."
  }
}

run "creates_one_reader_assignment_per_principal" {
  command = plan

  assert {
    condition     = length(azurerm_role_assignment.reader) == 2
    error_message = "Expected one role assignment for each entry in var.readers."
  }

  assert {
    condition     = alltrue([for assignment in azurerm_role_assignment.reader : assignment.role_definition_name == "Reader"])
    error_message = "Readers must get the Reader role and nothing broader."
  }
}

run "creates_no_assignment_without_readers" {
  command = plan

  variables {
    readers = {}
  }

  assert {
    condition     = length(azurerm_role_assignment.reader) == 0
    error_message = "No readers must mean no role assignments."
  }
}

run "rejects_unknown_sku" {
  command = plan

  variables {
    sku_name = "F1"
  }

  expect_failures = [var.sku_name]
}

# `id` is unknown during plan. An override with override_during = plan makes it
# known, so a plan run can check that the app uses the service plan of this module.
run "app_uses_its_own_service_plan" {
  command = plan

  override_resource {
    target          = azurerm_service_plan.this
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Web/serverFarms/asp-app-test"
    }
  }

  assert {
    condition     = azurerm_linux_web_app.this.service_plan_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Web/serverFarms/asp-app-test"
    error_message = "The app must run on the service plan this module creates."
  }
}

# With command = apply the mocked IDs from mock_provider above are known.
run "reader_roles_are_scoped_to_the_app" {
  command = apply

  assert {
    condition     = alltrue([for assignment in azurerm_role_assignment.reader : assignment.scope == azurerm_linux_web_app.this.id])
    error_message = "Reader roles must be scoped to the app, not to a wider scope."
  }
}
```

## What each part shows

| Part | Technique |
|---|---|
| `mock_resource ... defaults` | Valid IDs, so `command = apply` works |
| `override_data` | The local script never runs |
| `variables` at file level | Realistic shared inputs; runs override only what they test |
| `app_is_private_and_https_only` | Several asserts for one behaviour (the app is locked down) |
| `creates_..._per_principal` / `creates_no_...` | A `for_each` with entries and empty |
| `rejects_unknown_sku` | A rejected value with `expect_failures` |
| `app_uses_its_own_service_plan` | `override_during = plan` for a value unknown at plan |
| `reader_roles_are_scoped_to_the_app` | `command = apply` when IDs are needed |

## A `suggested_test` for a finding

If the app above had `ftps_state = "AllAllowed"`, the finding's `suggested_test` would be:

```hcl
run "ftp_deployment_is_disabled" {
  command = plan

  assert {
    condition     = azurerm_linux_web_app.this.site_config[0].ftps_state == "Disabled"
    error_message = "FTP deployment must be off: it sends credentials in plain text."
  }
}
```
