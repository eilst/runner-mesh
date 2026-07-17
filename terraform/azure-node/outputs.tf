output "node_name" {
  value = azurerm_linux_virtual_machine.node.name
}

output "public_ip" {
  description = "Outbound-only address — the NSG denies all inbound."
  value       = azurerm_public_ip.rm.ip_address
}

output "verify" {
  value = <<-EOT
    Within ~2 minutes the node should appear:
      kubectl get nodes -o wide      # expect ${var.node_name} Ready
    Bootstrap log (over tailnet, if ACL ssh rules allow):
      ssh ${var.admin_username}@${var.node_name} sudo cat /var/log/runner-mesh-bootstrap.log
    Or Azure serial console as break-glass.
  EOT
}
