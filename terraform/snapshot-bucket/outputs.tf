output "bucket" {
  value = aws_s3_bucket.snapshots.id
}

output "region" {
  value = var.region
}

output "endpoint" {
  description = "S3 endpoint for k3s --etcd-s3-endpoint."
  value       = "s3.${var.region}.amazonaws.com"
}

output "access_key_id" {
  value = aws_iam_access_key.snapshots.id
}

output "secret_access_key" {
  description = "IAM secret — sensitive. Lives in state; keep state private."
  value       = aws_iam_access_key.snapshots.secret
  sensitive   = true
}

# Copy-paste node:init invocation (run `terraform output -raw node_init_command`
# to get it with the secret filled in — don't echo it into shared logs).
output "node_init_command" {
  description = "Ready-to-run node:init with off-node snapshots wired to this bucket."
  sensitive   = true
  value = join(" ", [
    "runner-mesh node:init",
    "--snapshot-s3-endpoint s3.${var.region}.amazonaws.com",
    "--snapshot-s3-region ${var.region}",
    "--snapshot-s3-bucket ${aws_s3_bucket.snapshots.id}",
    "--snapshot-s3-folder ${var.snapshot_folder}",
    "--snapshot-s3-access-key ${aws_iam_access_key.snapshots.id}",
    "--snapshot-s3-secret-key ${aws_iam_access_key.snapshots.secret}",
  ])
}

# Same values for node:promote --snapshot-s3-* on recovery.
output "promote_s3_flags" {
  description = "The --snapshot-s3-* flags to pass to node:promote when restoring."
  sensitive   = true
  value = join(" ", [
    "--snapshot-s3-endpoint s3.${var.region}.amazonaws.com",
    "--snapshot-s3-region ${var.region}",
    "--snapshot-s3-bucket ${aws_s3_bucket.snapshots.id}",
    "--snapshot-s3-folder ${var.snapshot_folder}",
    "--snapshot-s3-access-key ${aws_iam_access_key.snapshots.id}",
    "--snapshot-s3-secret-key ${aws_iam_access_key.snapshots.secret}",
  ])
}
