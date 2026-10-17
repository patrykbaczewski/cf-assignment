mock_provider "azurerm" {}

variables {
  name                = "tp-test"
  resource_group_name = "rg-test"
  location            = "westeurope"
  address_space       = ["10.10.0.0/16"]
  subnets = {
    apps = {
      address_prefixes  = ["10.10.0.0/24"]
      service_endpoints = ["Microsoft.Storage"]
    }
    data = {
      address_prefixes = ["10.10.1.0/24"]
    }
  }
}

run "creates_one_subnet_and_nsg_per_key" {
  command = plan

  assert {
    condition     = length(azurerm_subnet.this) == 2
    error_message = "Expected one subnet for each key in var.subnets."
  }

  assert {
    condition     = length(azurerm_network_security_group.this) == 2
    error_message = "Expected one network security group for each subnet."
  }

  assert {
    condition     = length(azurerm_subnet_network_security_group_association.this) == 2
    error_message = "Every subnet must be associated with its network security group."
  }
}

run "names_follow_the_convention" {
  command = plan

  assert {
    condition     = azurerm_virtual_network.this.name == "vnet-tp-test"
    error_message = "The virtual network name must start with vnet-."
  }

  assert {
    condition     = azurerm_subnet.this["apps"].name == "snet-apps"
    error_message = "Subnet names must start with snet-."
  }

  assert {
    condition     = azurerm_network_security_group.this["apps"].name == "nsg-tp-test-apps"
    error_message = "NSG names must be nsg-<name>-<subnet key>, so each NSG is unique per network and subnet."
  }
}

run "creates_no_subnets_or_nsgs_without_subnets" {
  command = plan

  variables {
    subnets = {}
  }

  assert {
    condition     = length(azurerm_subnet.this) == 0 && length(azurerm_network_security_group.this) == 0 && length(azurerm_subnet_network_security_group_association.this) == 0
    error_message = "No subnets must mean no subnets, NSGs or associations."
  }

  assert {
    condition     = azurerm_virtual_network.this.name == "vnet-tp-test"
    error_message = "The virtual network must still be created when there are no subnets."
  }
}

run "subnets_belong_to_the_module_vnet" {
  command = plan

  assert {
    condition     = alltrue([for subnet in azurerm_subnet.this : subnet.virtual_network_name == azurerm_virtual_network.this.name])
    error_message = "Every subnet must be created in the virtual network this module creates."
  }
}

run "service_endpoints_default_to_none" {
  command = plan

  assert {
    condition     = length(azurerm_subnet.this["data"].service_endpoints) == 0
    error_message = "A subnet without service_endpoints must get none: endpoints open paths to PaaS services."
  }

  assert {
    condition     = azurerm_subnet.this["apps"].service_endpoints == toset(["Microsoft.Storage"])
    error_message = "A subnet must get exactly the service endpoints it asks for."
  }
}

run "each_subnet_is_associated_with_its_own_nsg" {
  command = plan

  override_resource {
    target          = azurerm_subnet.this["apps"]
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-tp-test/subnets/snet-apps"
    }
  }

  override_resource {
    target          = azurerm_subnet.this["data"]
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-tp-test/subnets/snet-data"
    }
  }

  override_resource {
    target          = azurerm_network_security_group.this["apps"]
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/networkSecurityGroups/nsg-tp-test-apps"
    }
  }

  override_resource {
    target          = azurerm_network_security_group.this["data"]
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/networkSecurityGroups/nsg-tp-test-data"
    }
  }

  assert {
    condition     = azurerm_subnet_network_security_group_association.this["apps"].subnet_id == azurerm_subnet.this["apps"].id && azurerm_subnet_network_security_group_association.this["apps"].network_security_group_id == azurerm_network_security_group.this["apps"].id
    error_message = "The apps subnet must be protected by the apps NSG, not another subnet's NSG."
  }

  assert {
    condition     = azurerm_subnet_network_security_group_association.this["data"].subnet_id == azurerm_subnet.this["data"].id && azurerm_subnet_network_security_group_association.this["data"].network_security_group_id == azurerm_network_security_group.this["data"].id
    error_message = "The data subnet must be protected by the data NSG, not another subnet's NSG."
  }

  assert {
    condition     = output.subnet_ids["data"] == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-tp-test/subnets/snet-data"
    error_message = "subnet_ids must map each subnet key to the ID of that subnet."
  }
}

run "rejects_invalid_address_space" {
  command = plan

  variables {
    address_space = ["not-a-cidr"]
  }

  expect_failures = [var.address_space]
}

run "rejects_one_invalid_range_among_valid_ones" {
  command = plan

  variables {
    address_space = ["10.10.0.0/16", "10.20.0.0/33"]
  }

  expect_failures = [var.address_space]
}
