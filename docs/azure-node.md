# Azure node for runner-mesh

Provisions one always-on Linux VM and joins it to the cluster over the
tailnet — the reliable home for the `large` amd64 pool (laptops sleep;
this doesn't).

## Security model

- **Zero inbound**: the NSG has no allow rules (plus an explicit deny).
  The public IP exists only for outbound internet. Admin access rides
  the tailnet (`tailscale set --ssh`, governed by your ACL) with Azure
  serial console as break-glass.
- **Join key**: minted at `apply` from the fleet's OAuth client
  (`~/.config/runner-mesh/tailscale.json`) — single-use, pre-authorized,
  tagged `tag:runner-mesh-node`, expires in 1 h. Never enters the repo.
- **Cluster token**: lives only in your gitignored `terraform.tfvars`
  (or `TF_VAR_cluster_token`), and consequently in local state —
  **state files are gitignored; keep them that way.** For multi-machine
  ops move state to a private encrypted backend.
- The pod route this node advertises (`10.42.x.0/24`) is auto-approved
  by the ACL's `autoApprovers` — no console step needed.

## Usage

```bash
az login                                       # once (or ARM_* env-var auth)
cp terraform.tfvars.example terraform.tfvars   # fill in cluster_token + server_ip
terraform init && terraform apply
```

Fleet repos typically wrap this as a module pinned to an engine ref:

```hcl
module "azure_node" {
  source        = "git::https://github.com/eilst/runner-mesh.git//terraform/azure-node?ref=<engine-ref>"
  cluster_token = var.cluster_token
  server_ip     = "100.x.y.z"
}
```

Then verification from any operator machine: `kubectl get nodes` →
the node `Ready`, with `runner-mesh.dev/size` already applied via
`--node-label` when `size_label` is set.

## Rebuilding the VM

The join key in state is long-expired after the first hour, so a VM
rebuild must re-mint it in the same apply:

```bash
terraform apply -replace=tailscale_tailnet_key.node -replace=azurerm_linux_virtual_machine.node
```

Afterwards delete the old node object once (`kubectl delete node
runner-mesh-azure-1`) if the name was reused before the old entry aged out,
and remove the stale device in the Tailscale console.

## arm64 variant

Just set `vm_size = "Standard_D4ps_v5"` (or any `p`-series size) — the
Ubuntu image sku follows the size's architecture automatically. Leave
`size_label` empty unless you run a pool that selects arm64: a pool whose
nodeSelector requires amd64 will never schedule on an arm64 node.

Subscription note: startup/free Azure subscriptions are often
capacity-restricted to arm64 (`p`-series) plus the DCsv3 confidential
family for amd64. Check before picking a size:
`az vm list-skus -l <region> --resource-type virtualMachines` and look
for entries with empty `restrictions`.
