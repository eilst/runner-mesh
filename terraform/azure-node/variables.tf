variable "cluster_token" {
  description = "k3s cluster join token (from the server install). Put it in the gitignored terraform.tfvars or pass via TF_VAR_cluster_token — never commit it."
  type        = string
  sensitive   = true
}

variable "server_ip" {
  description = "Tailnet IP of your k3s server (the runner-mesh-server machine)."
  type        = string
}

variable "node_name" {
  description = "k8s node name AND tailnet hostname for this node."
  type        = string
  default     = "runner-mesh-azure-1"
}

variable "size_label" {
  description = "Value for the runner-mesh.dev/size node label (e.g. \"large\" to serve a size-selected pool; \"\" for no label). Keep it consistent with the node's arch — a pool selecting amd64 never schedules on an arm64 node."
  type        = string
  default     = ""
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "canadacentral"
}

variable "resource_group_name" {
  description = "Resource group to create for this node."
  type        = string
  default     = "runner-mesh"
}

variable "vm_size" {
  description = "VM size. amd64 sizes (D*s_v5) serve the large pool; arm64 sizes (D*ps_v5/v6) serve the base pool — keep size_label consistent with the arch."
  type        = string
  default     = "Standard_D4s_v5" # amd64, 4 vCPU / 16 GiB — fits the large pool's 4-CPU/8Gi limits
}

variable "os_disk_gb" {
  description = "OS disk size. Ephemeral dind runners are disk-hungry; size generously."
  type        = number
  default     = 128
}

variable "spot_enabled" {
  description = "Run as a Spot VM (much cheaper, can be evicted — fine for CI capacity, not for the only large node)."
  type        = bool
  default     = false
}

variable "admin_username" {
  description = "VM admin user (only reachable over the tailnet — no inbound NSG rules exist)."
  type        = string
  default     = "ops"
}

variable "admin_ssh_pubkey_path" {
  description = "SSH public key for the VM admin user (break-glass via Azure serial console / tailnet SSH)."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "tailscale_config_path" {
  description = "Path to the fleet's tailscale OAuth client JSON (created by `runner-mesh net:init`). Never committed."
  type        = string
  default     = "~/.config/runner-mesh/tailscale.json"
}

variable "tailscale_tag" {
  description = "ACL tag applied to the minted key / device."
  type        = string
  default     = "tag:runner-mesh-node"
}
