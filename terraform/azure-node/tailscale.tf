# Single-use, pre-authorized, tagged join key — same shape `runner-mesh
# net:key` mints. It expires 1 hour after apply: long-dead in state, but
# consumed by the VM within its first boot minute. Rebuilding the VM
# later requires re-minting (see README's rebuild command).
resource "tailscale_tailnet_key" "node" {
  reusable      = false
  ephemeral     = false
  preauthorized = true
  expiry        = 3600
  tags          = [var.tailscale_tag]
  description   = "runner-mesh azure node join - ${var.node_name}"
}
