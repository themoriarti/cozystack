#!/bin/bash
# Step 03: Provision an in-cluster Bucket and stash its S3 coordinates so step
# 04 can pass them to the ClickHouse application's `backup.*` values. The
# clickhouse chart materialises `<release>-backup-s3` and the
# clickhouse-backup sidecar from those values; the backup strategy then
# consumes the chart-emitted Secret without any tenant-side glue.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-helpers.sh"

print_header "Step 03: Provision Bucket '${BUCKET_NAME}' in '${NAMESPACE}'"

log_command "kubectl apply -f - (Bucket: $BUCKET_NAME)"
# spec.users.backup is required for the Bucket app to provision a
# BucketAccess (and credentials Secret) the backup tooling can read.
kubectl apply -f - <<EOF
apiVersion: apps.cozystack.io/v1alpha1
kind: Bucket
metadata:
  name: ${BUCKET_NAME}
  namespace: ${NAMESPACE}
spec:
  users:
    backup:
      readonly: false
EOF

log_substep "Waiting for bucket HelmRelease to be Ready..."
wait_hr_ready "bucket-${BUCKET_NAME}" 300
kubectl -n "$NAMESPACE" wait bucketclaims.objectstorage.k8s.io "bucket-${BUCKET_NAME}" --for=jsonpath='{.status.bucketReady}'=true --timeout=180s
# Cozystack's bucket app provisions a BucketAccess named "<bucket-name>-backup"
# (the "-backup" suffix is the BucketAccessClass name); the BucketInfo Secret
# carries the same name.
kubectl -n "$NAMESPACE" wait bucketaccesses.objectstorage.k8s.io "bucket-${BUCKET_NAME}-backup" --for=jsonpath='{.status.accessGranted}'=true --timeout=180s

log_substep "Reading bucket coordinates from BucketInfo Secret..."
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
kubectl -n "$NAMESPACE" get secret "bucket-${BUCKET_NAME}-backup" -o jsonpath='{.data.BucketInfo}' | base64 -d > "$TMP"

CH_BACKUP_ACCESS_KEY=$(jq -r '.spec.secretS3.accessKeyID' "$TMP")
CH_BACKUP_SECRET_KEY=$(jq -r '.spec.secretS3.accessSecretKey' "$TMP")
# S3_ENDPOINT can be overridden via the environment: BucketInfo advertises the
# EXTERNAL ingress endpoint, which in-cluster Pods cannot always reach or
# TLS-validate (in CI it is the unroutable s3.example.org placeholder); the
# in-cluster alternative is https://seaweedfs-s3.<ns>:8333, trusted via the CA
# copied below.
CH_BACKUP_ENDPOINT="${S3_ENDPOINT:-$(jq -r '.spec.secretS3.endpoint' "$TMP")}"
CH_BACKUP_REGION=$(jq -r 'if (.spec.secretS3.region // "") == "" then "us-east-1" else .spec.secretS3.region end' "$TMP")
CH_BACKUP_BUCKET=$(jq -r '.spec.bucketName' "$TMP")

# `jq -r` returns the literal string "null" for missing JSON paths; fail fast
# here so the missing field surfaces at extraction time instead of as a
# confusing helm/CHI error after the cache is sourced by 04 / 07.
for v in CH_BACKUP_ACCESS_KEY CH_BACKUP_SECRET_KEY CH_BACKUP_ENDPOINT CH_BACKUP_REGION CH_BACKUP_BUCKET; do
    [[ -n "${!v}" && "${!v}" != "null" ]] || { log_error "BucketInfo missing required field: ${v}"; exit 1; }
done

# Resolve and copy the S3 endpoint CA. The default name tracks the seaweedfs
# chart's fullnameOverride (seaweedfs -> seaweedfs-ca-cert), but a downstream
# fullname change would rename it, so fall back to discovering the cert-manager
# CA Certificate (the seaweedfs-labelled one with spec.isCA=true) and read its
# secretName. Leave S3_CA_SECRET empty to skip the copy on a public-CA endpoint.
CH_BACKUP_CA_SECRET=""
if [[ -n "$S3_CA_SECRET" ]]; then
    if ! kubectl -n "$S3_CA_NAMESPACE" get secret "$S3_CA_SECRET" >/dev/null 2>&1; then
        log_warning "S3 CA secret ${S3_CA_NAMESPACE}/${S3_CA_SECRET} not found; discovering the seaweedfs CA Certificate..."
        # List every seaweedfs Certificate as "<isCA> <secretName>" and pick the
        # CA one in shell — avoids kubectl jsonpath's finicky boolean-literal
        # filter.
        DISCOVERED_CA=$(kubectl -n "$S3_CA_NAMESPACE" get certificates.cert-manager.io \
            -l app.kubernetes.io/name=seaweedfs \
            -o jsonpath='{range .items[*]}{.spec.isCA}{" "}{.spec.secretName}{"\n"}{end}' 2>/dev/null \
            | awk '$1=="true"{print $2; exit}' || true)
        if [[ -n "$DISCOVERED_CA" ]]; then
            log_success "Discovered seaweedfs CA secret ${S3_CA_NAMESPACE}/${DISCOVERED_CA}"
            S3_CA_SECRET="$DISCOVERED_CA"
        else
            log_error "No seaweedfs CA Certificate found in ${S3_CA_NAMESPACE}; set S3_CA_SECRET explicitly (or empty for a public-CA endpoint)."
            exit 1
        fi
    fi
    log_substep "Copying S3 CA ${S3_CA_NAMESPACE}/${S3_CA_SECRET}[${S3_CA_KEY}] -> ${CH_CA_SECRET_NAME}..."
    # The dot in the default key has to be escaped for kubectl jsonpath.
    ca_pem=$(kubectl -n "$S3_CA_NAMESPACE" get secret "$S3_CA_SECRET" \
        -o jsonpath="{.data.${S3_CA_KEY//./\\.}}" | base64 -d)
    [[ -n "$ca_pem" ]] || { log_error "S3 CA secret ${S3_CA_NAMESPACE}/${S3_CA_SECRET} has no ${S3_CA_KEY}"; exit 1; }
    # apply (not create) so a stale copy from an earlier run is corrected.
    kubectl -n "$NAMESPACE" create secret generic "$CH_CA_SECRET_NAME" \
        --from-literal="ca.crt=${ca_pem}" \
        --dry-run=client -o yaml | kubectl apply -f -
    CH_BACKUP_CA_SECRET="$CH_CA_SECRET_NAME"
else
    log_warning "S3_CA_SECRET empty: leaving backup.endpointCA unset (assumes a publicly-trusted S3 endpoint)."
fi

# Persist for the next step. 04-create-clickhouse.sh sources this file when it
# applies the ClickHouse spec so the chart can render <release>-backup-s3.
# The cache stores raw S3 credentials, so apply restrictive perms before
# writing the body - umask alone could leave the file group/world-readable.
umask 077
cat > "$SCRIPT_DIR/.bucket-info.env" <<ENV
export CH_BACKUP_ACCESS_KEY=${CH_BACKUP_ACCESS_KEY}
export CH_BACKUP_SECRET_KEY=${CH_BACKUP_SECRET_KEY}
export CH_BACKUP_ENDPOINT=${CH_BACKUP_ENDPOINT}
export CH_BACKUP_REGION=${CH_BACKUP_REGION}
export CH_BACKUP_BUCKET=${CH_BACKUP_BUCKET}
export CH_BACKUP_CA_SECRET=${CH_BACKUP_CA_SECRET}
ENV
chmod 600 "$SCRIPT_DIR/.bucket-info.env"

log_success "Bucket '${BUCKET_NAME}' ready; coordinates cached in $(basename "$SCRIPT_DIR")/.bucket-info.env."
echo -e "\n${GREEN}${BOLD}Next:${NC} ./04-create-clickhouse.sh"
