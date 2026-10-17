# A mocked provider: no Azure, no credentials. All runs use command = plan.
mock_provider "azurerm" {}

# Realistic values: the mocked provider still checks formats (names and IDs).
variables {
  name                = "stdatadev001-blob"
  resource_group_name = "rg-test"
  location            = "westeurope"
  subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-private-endpoints"
  target_resource_id  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/stdatadev001"
  subresource_name    = "blob"
  private_dns_zone_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
}

run "names_follow_the_pe_and_psc_convention" {
  command = plan

  assert {
    condition     = azurerm_private_endpoint.this.name == "pe-stdatadev001-blob"
    error_message = "The endpoint name must be the name suffix with the pe- prefix, so endpoints are recognisable across the platform."
  }

  assert {
    condition     = azurerm_private_endpoint.this.private_service_connection[0].name == "psc-stdatadev001-blob"
    error_message = "The service connection name must be the name suffix with the psc- prefix."
  }
}

run "connects_automatically_to_the_target_subresource" {
  command = plan

  assert {
    condition     = azurerm_private_endpoint.this.private_service_connection[0].is_manual_connection == false
    error_message = "The connection must be approved automatically: a manual connection stays pending and the endpoint carries no traffic."
  }

  assert {
    condition     = azurerm_private_endpoint.this.private_service_connection[0].private_connection_resource_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/stdatadev001"
    error_message = "The endpoint must connect to the target resource given in var.target_resource_id."
  }

  assert {
    condition     = azurerm_private_endpoint.this.private_service_connection[0].subresource_names == tolist(["blob"])
    error_message = "The endpoint must connect to exactly the one sub-resource given in var.subresource_name."
  }
}

run "creates_dns_zone_group_when_zone_is_given" {
  command = plan

  assert {
    condition     = length(azurerm_private_endpoint.this.private_dns_zone_group) == 1
    error_message = "A private DNS zone ID must create one DNS zone group, so the endpoint name resolves to its private IP."
  }

  assert {
    condition     = azurerm_private_endpoint.this.private_dns_zone_group[0].private_dns_zone_ids == tolist(["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"])
    error_message = "The DNS zone group must register the endpoint in exactly the zone given in var.private_dns_zone_id."
  }
}

run "creates_no_dns_zone_group_without_zone" {
  command = plan

  variables {
    private_dns_zone_id = null
  }

  assert {
    condition     = length(azurerm_private_endpoint.this.private_dns_zone_group) == 0
    error_message = "Without a private DNS zone ID the endpoint must have no DNS zone group."
  }
}
