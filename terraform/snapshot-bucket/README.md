# etcd snapshot bucket (AWS S3)

Provisions the **off-node** store for control-plane snapshots that
`node:init` writes and `node:promote` restores from (see
`docs/control-plane-recovery.md`). One `terraform apply` creates:

- a private, encrypted S3 bucket (public access blocked, SSE-S3, versioned)
- a lifecycle rule that expires snapshots older than `retention_days`
- a **least-privilege IAM user** (read/write/list/delete on *only* this
  bucket) + access key

## Why S3 (not Azure Blob)

k3s's snapshot uploader speaks the S3 API. Azure Blob is **not** S3-compatible
natively, so it can't be a k3s `--etcd-s3` target. AWS S3 (or any S3-API store —
R2, B2, MinIO) works. Putting snapshots on a **different provider/region than
the control plane** is a feature: a cloud/region outage that kills the server
doesn't also take the snapshots you'd restore from.

## Usage

```bash
aws sso login   # or any AWS credential setup
cp terraform.tfvars.example terraform.tfvars   # optional: pin region/name
terraform init && terraform apply
```

Then wire it into the control plane. The bucket details (including the secret)
come out as ready-to-run commands:

```bash
# New control plane:
eval "$(terraform output -raw node_init_command)"     # prints node:init ... run it

# Existing control plane (no rebuild) — append the S3 lines to its k3s config
# and restart, e.g. via `az vm run-command` / ssh:
terraform output -raw promote_s3_flags                 # the --snapshot-s3-* values
```

> The `node_init_command` / `promote_s3_flags` outputs are `sensitive` (they
> contain the IAM secret). Use `terraform output -raw <name>` to read them
> deliberately; they won't print in normal `terraform apply` logs.

## Verify snapshots are landing

On the control-plane node:

```bash
sudo k3s etcd-snapshot list --etcd-s3 --etcd-s3-bucket <bucket> \
  --etcd-s3-endpoint s3.<region>.amazonaws.com --etcd-s3-access-key <k> --etcd-s3-secret-key <s>
```

## Cost

etcd snapshots are small (single-digit MB each). At `retention_days=30` and a
6-hourly schedule that's on the order of hundreds of MB — cents/month of S3.

## State hygiene

The IAM secret access key lives in Terraform **state**. Keep state local and
gitignored, or use an encrypted remote backend. Never commit it.
