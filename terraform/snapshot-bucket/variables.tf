variable "region" {
  description = "AWS region for the snapshot bucket. Pick one geographically separate from your control-plane node so a regional outage doesn't take both."
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "S3 bucket name (must be globally unique). Leave empty to auto-generate 'runner-mesh-etcd-snapshots-<random>'."
  type        = string
  default     = ""
}

variable "snapshot_folder" {
  description = "Key prefix (folder) inside the bucket for snapshots. Matches node:init's --snapshot-s3-folder."
  type        = string
  default     = "runner-mesh"
}

variable "retention_days" {
  description = "Lifecycle backstop: hard-delete snapshot objects older than this. Complements k3s's own --snapshot-retention count (belt and suspenders, and reclaims cost)."
  type        = number
  default     = 30
}

variable "iam_user_name" {
  description = "Name of the least-privilege IAM user k3s uses to read/write snapshots."
  type        = string
  default     = "runner-mesh-etcd-snapshots"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = { app = "runner-mesh", purpose = "etcd-snapshots" }
}
