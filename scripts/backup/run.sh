#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT="/backups/sites"
RETENTION_FILES="${BACKUP_RETENTION_DAYS_FILES:-14}"
RETENTION_DB="${BACKUP_RETENTION_DAYS_DB:-14}"
DB_NAME_PREFIX="${DB_NAME_PREFIX:-db_}"

ensure_kubeconfig() {
  if [[ -n "${KUBECONFIG:-}" ]]; then
    return
  fi
  if [[ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]]; then
    cat > /tmp/kubeconfig <<'EOF'
apiVersion: v1
kind: Config
clusters:
- name: in-cluster
  cluster:
    certificate-authority: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    server: https://kubernetes.default.svc
users:
- name: sa
  user:
    tokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
contexts:
- name: in-cluster
  context:
    cluster: in-cluster
    user: sa
    namespace: backup-zone
current-context: in-cluster
EOF
    export KUBECONFIG=/tmp/kubeconfig
  fi
}

ensure_kubeconfig

mkdir -p "${BACKUP_ROOT}"

mapfile -t TENANT_LINES < <(
  kubectl get namespaces -l vhp-controller=vhp-controller \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.vhp\.site-slug}{"\n"}{end}'
)

if [[ "${#TENANT_LINES[@]}" -eq 0 ]]; then
  echo "No tenant namespaces found."
  exit 0
fi

for line in "${TENANT_LINES[@]}"; do
  namespace="$(printf "%s" "${line}" | cut -f1)"
  slug="$(printf "%s" "${line}" | cut -f2)"
  if [[ -z "${slug}" ]]; then
    continue
  fi

  timestamp="$(date -u +"%Y%m%dT%H%M%SZ")"
  site_dir="${BACKUP_ROOT}/${slug}"
  files_dir="${site_dir}/files"
  db_dir="${site_dir}/db"
  mkdir -p "${files_dir}" "${db_dir}"

  files_status="skipped"
  files_path=""
  if kubectl -n "${namespace}" get pvc site-data >/dev/null 2>&1; then
    pod_name="backup-export-${slug}-$(date +%s)"
    cat <<EOF | kubectl -n "${namespace}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  labels:
    app.kubernetes.io/name: backup-export
spec:
  restartPolicy: Never
  containers:
  - name: exporter
    image: alpine:3.19
    command: ["sleep","3600"]
    volumeMounts:
    - name: site-data
      mountPath: /data
      readOnly: true
  volumes:
  - name: site-data
    persistentVolumeClaim:
      claimName: site-data
      readOnly: true
EOF

    if kubectl -n "${namespace}" wait --for=condition=Ready pod/"${pod_name}" --timeout=120s; then
      files_path="${files_dir}/${timestamp}.tar.zst"
      if kubectl -n "${namespace}" exec "${pod_name}" -- tar -C /data -cf - . | zstd -T0 -q -o "${files_path}"; then
        files_status="ok"
      else
        files_status="error"
        rm -f "${files_path}"
      fi
    else
      files_status="error"
    fi

    kubectl -n "${namespace}" delete pod "${pod_name}" --ignore-not-found >/dev/null 2>&1 || true
  else
    echo "Missing PVC site-data in ${namespace}; skipping file backup."
    echo "Missing PVC site-data" > "${files_dir}/SKIPPED.txt"
    files_status="missing_pvc"
  fi

  db_status="skipped"
  db_path=""
  db_user="${DB_ADMIN_USER:-${DB_USER:-}}"
  db_password="${DB_ADMIN_PASSWORD:-${DB_PASSWORD:-}}"
  if [[ -n "${DB_HOST:-}" && -n "${db_user}" && -n "${db_password}" ]]; then
    db_port="${DB_PORT:-5432}"
    db_path="${db_dir}/${timestamp}.sql.gz"
    if PGPASSWORD="${db_password}" pg_dump -h "${DB_HOST}" -p "${db_port}" -U "${db_user}" \
      "${DB_NAME_PREFIX}${slug}" | gzip -c > "${db_path}"; then
      db_status="ok"
    else
      db_status="error"
      rm -f "${db_path}"
    fi
  else
    echo "DB env vars not set" > "${db_dir}/SKIPPED.txt"
    db_status="skipped"
  fi

  cat > "${site_dir}/meta.json" <<EOF
{
  "timestamp": "${timestamp}",
  "namespace": "${namespace}",
  "slug": "${slug}",
  "files": {
    "status": "${files_status}",
    "path": "${files_path}"
  },
  "db": {
    "status": "${db_status}",
    "path": "${db_path}"
  }
}
EOF

  find "${files_dir}" -type f -name "*.tar.zst" -mtime +"${RETENTION_FILES}" -delete || true
  find "${db_dir}" -type f -name "*.sql.gz" -mtime +"${RETENTION_DB}" -delete || true
done
