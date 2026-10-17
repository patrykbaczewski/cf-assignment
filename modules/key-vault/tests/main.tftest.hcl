# A mocked provider: no Azure, no credentials. The vault and the role definition get
# valid Azure IDs, so apply runs can check the wiring between resources.
mock_provider "azurerm" {
  mock_resource "azurerm_key_vault" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.KeyVault/vaults/kv-tp-test"
    }
  }

  mock_data "azurerm_role_definition" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6"
    }
  }
}

variables {
  name                = "kv-tp-test"
  resource_group_name = "rg-test"
  location            = "westeurope"
  tenant_id           = "00000000-0000-0000-0000-000000000000"
  secret_readers = {
    adf = "11111111-1111-1111-1111-111111111111"
  }
}

run "vault_uses_rbac_and_purge_protection" {
  command = plan

  assert {
    condition     = azurerm_key_vault.this.rbac_authorization_enabled == true
    error_message = "The vault must use role-based access, not access policies."
  }

  assert {
    condition     = azurerm_key_vault.this.purge_protection_enabled == true
    error_message = "Purge protection must be on."
  }

  assert {
    condition     = azurerm_key_vault.this.soft_delete_retention_days == 30
    error_message = "Deleted vault objects must stay recoverable for 30 days, so an accidental delete can be undone."
  }
}

run "network_denies_by_default" {
  command = plan

  assert {
    condition     = azurerm_key_vault.this.network_acls[0].default_action == "Deny"
    error_message = "The vault firewall must deny by default: only listed subnets may reach it."
  }

  assert {
    condition     = azurerm_key_vault.this.network_acls[0].bypass == "AzureServices"
    error_message = "Only trusted Azure services may bypass the vault firewall."
  }
}

run "allowed_subnets_reach_the_vault" {
  command = plan

  variables {
    allowed_subnet_ids = [
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-app",
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-data",
    ]
  }

  assert {
    condition     = length(azurerm_key_vault.this.network_acls[0].virtual_network_subnet_ids) == 2
    error_message = "Exactly the subnets in var.allowed_subnet_ids must be allowed through the vault firewall."
  }

  assert {
    condition     = contains(azurerm_key_vault.this.network_acls[0].virtual_network_subnet_ids, "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-app")
    error_message = "Every subnet in var.allowed_subnet_ids must be allowed through the vault firewall."
  }

  assert {
    condition     = contains(azurerm_key_vault.this.network_acls[0].virtual_network_subnet_ids, "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-data")
    error_message = "Every subnet in var.allowed_subnet_ids must be allowed through the vault firewall."
  }
}

run "no_subnet_is_allowed_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_key_vault.this.network_acls[0].virtual_network_subnet_ids) == 0
    error_message = "Without allowed_subnet_ids no subnet may pass the vault firewall."
  }
}

run "creates_one_role_assignment_per_reader" {
  command = plan

  variables {
    secret_readers = {
      adf        = "11111111-1111-1111-1111-111111111111"
      databricks = "22222222-2222-2222-2222-222222222222"
    }
  }

  assert {
    condition     = length(azurerm_role_assignment.secret_reader) == 2
    error_message = "Expected one role assignment for each secret reader."
  }

  assert {
    condition     = azurerm_role_assignment.secret_reader["adf"].principal_id == "11111111-1111-1111-1111-111111111111"
    error_message = "Each assignment must be keyed by the reader's short key and grant the role to its object ID."
  }

  assert {
    condition     = azurerm_role_assignment.secret_reader["databricks"].principal_id == "22222222-2222-2222-2222-222222222222"
    error_message = "Each assignment must be keyed by the reader's short key and grant the role to its object ID."
  }
}

run "creates_no_assignment_without_readers" {
  command = plan

  variables {
    secret_readers = {}
  }

  assert {
    condition     = length(azurerm_role_assignment.secret_reader) == 0
    error_message = "No secret readers must mean no role assignments."
  }
}

run "readers_get_only_secrets_user_on_this_vault" {
  command = apply

  assert {
    condition     = data.azurerm_role_definition.secrets_user.name == "Key Vault Secrets User"
    error_message = "Readers must get Key Vault Secrets User, a read-only role, and nothing broader."
  }

  assert {
    condition     = alltrue([for assignment in azurerm_role_assignment.secret_reader : assignment.role_definition_id == data.azurerm_role_definition.secrets_user.id])
    error_message = "Every reader assignment must use the Key Vault Secrets User role definition."
  }

  assert {
    condition     = alltrue([for assignment in azurerm_role_assignment.secret_reader : assignment.scope == azurerm_key_vault.this.id])
    error_message = "Reader roles must be scoped to this vault, not to a wider scope."
  }
}
