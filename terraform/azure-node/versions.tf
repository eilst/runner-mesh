terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = ">= 0.17.0, < 1.0.0"
    }
  }

  # State stays LOCAL and gitignored: it contains the cluster token and
  # the (single-use, 1h) tailscale key. If more than one machine will
  # manage this node, move to an encrypted remote backend (private Azure
  # storage account) instead of committing or copying state files.
}

provider "azurerm" {
  # Auth: `az login` or ARM_* env vars. Subscription comes from
  # ARM_SUBSCRIPTION_ID or the az CLI default.
  features {}
}

# Mints the node's join key at apply time from the same OAuth client the
# fleet already uses (~/.config/runner-mesh/tailscale.json) — the key
# never lives in the repo and expires in 1 hour.
provider "tailscale" {
  oauth_client_id     = local.ts_config.client_id
  oauth_client_secret = local.ts_config.client_secret
}

locals {
  ts_config = jsondecode(file(pathexpand(var.tailscale_config_path)))
}
