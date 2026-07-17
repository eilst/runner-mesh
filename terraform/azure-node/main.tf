locals {
  # arm64 sizes carry a "p" right after the size digits (D4ps_v5,
  # B2pts_v2, ...) — pick the matching Ubuntu image automatically.
  is_arm64  = can(regex("^Standard_[A-Z]+[0-9]+p", var.vm_size))
  image_sku = local.is_arm64 ? "server-arm64" : "server"
}

resource "azurerm_resource_group" "rm" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_virtual_network" "rm" {
  name                = "${var.node_name}-vnet"
  location            = azurerm_resource_group.rm.location
  resource_group_name = azurerm_resource_group.rm.name
  address_space       = ["10.60.0.0/24"]
}

resource "azurerm_subnet" "rm" {
  name                 = "nodes"
  resource_group_name  = azurerm_resource_group.rm.name
  virtual_network_name = azurerm_virtual_network.rm.name
  address_prefixes     = ["10.60.0.0/26"]
}

# Zero inbound. Tailscale needs only OUTBOUND connectivity (443 + UDP
# 41641 + DERP fallback); node admin happens over the tailnet, and the
# cluster reaches the node the same way. The explicit rule documents the
# posture on top of Azure's default DenyAllInBound.
resource "azurerm_network_security_group" "rm" {
  name                = "${var.node_name}-nsg"
  location            = azurerm_resource_group.rm.location
  resource_group_name = azurerm_resource_group.rm.name

  security_rule {
    name                       = "deny-all-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# Public IP exists ONLY to provide outbound internet (Azure retired
# default outbound access for new subnets); the NSG blocks everything
# inbound. Swap for a NAT Gateway if you'd rather have no public IP at all.
resource "azurerm_public_ip" "rm" {
  name                = "${var.node_name}-pip"
  location            = azurerm_resource_group.rm.location
  resource_group_name = azurerm_resource_group.rm.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "rm" {
  name                = "${var.node_name}-nic"
  location            = azurerm_resource_group.rm.location
  resource_group_name = azurerm_resource_group.rm.name

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.rm.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.rm.id
  }
}

resource "azurerm_network_interface_security_group_association" "rm" {
  network_interface_id      = azurerm_network_interface.rm.id
  network_security_group_id = azurerm_network_security_group.rm.id
}

resource "azurerm_linux_virtual_machine" "node" {
  name                = var.node_name
  location            = azurerm_resource_group.rm.location
  resource_group_name = azurerm_resource_group.rm.name
  size                = var.vm_size
  admin_username      = var.admin_username

  network_interface_ids = [azurerm_network_interface.rm.id]

  priority        = var.spot_enabled ? "Spot" : "Regular"
  eviction_policy = var.spot_enabled ? "Deallocate" : null

  disable_password_authentication = true
  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.admin_ssh_pubkey_path))
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.os_disk_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = local.image_sku # follows vm_size arch automatically
    version   = "latest"
  }

  # cloud-init runs this as root on first boot: tailscale + k3s agent
  # join (same plan node:join prints, minus the colima-only steps).
  # Changing the script forces VM replacement — see README for the
  # rebuild command that also re-mints the (single-use) join key.
  custom_data = base64encode(templatefile("${path.module}/cloud-init.sh.tpl", {
    node_name         = var.node_name
    server_ip         = var.server_ip
    cluster_token     = var.cluster_token
    size_label        = var.size_label
    tailscale_authkey = tailscale_tailnet_key.node.key
  }))

  boot_diagnostics {} # managed storage — serial console is the break-glass
}
