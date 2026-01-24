import { LABELS } from "../k8s/client.js";
import { USER_HOME_PVC_NAME, USER_BACKUP_PVC_NAME } from "../k8s/pvc.js";
export function buildRestorePod(spec) {
    // Handle "latest" by finding the most recent backup file
    const isLatest = spec.archivePath.includes("/latest");
    const dir = spec.archivePath.substring(0, spec.archivePath.lastIndexOf("/"));
    const findLatestCmd = isLatest 
        ? `latest_file=$(find "${dir}" -type f \\( -name "*.tar.gz" -o -name "*.tar.zst" \\) -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-); if [ -z "$latest_file" ]; then echo "No backup found" >&2; exit 1; fi; archive_path="$latest_file"`
        : `archive_path="${spec.archivePath}"`;
    
    const command = `apk add --no-cache gzip zstd >/dev/null 2>&1 && ${findLatestCmd} && if [ -z "$archive_path" ]; then echo "Archive not found" >&2; exit 1; fi && rm -rf /home/* /home/.[!.]* /home/..?* && if echo "$archive_path" | grep -q "\\.tar\\.zst$"; then tar --use-compress-program=zstd -xf "$archive_path" -C /home; else tar -xzf "$archive_path" -C /home; fi`;
    return {
        apiVersion: "v1",
        kind: "Pod",
        metadata: {
            name: spec.name,
            namespace: spec.namespace,
            labels: {
                [LABELS.managedBy]: LABELS.managedBy,
                [LABELS.siteSlug]: spec.slug,
                "app.kubernetes.io/name": "restore-files"
            }
        },
        spec: {
            restartPolicy: "Never",
            containers: [
                {
                    name: "restore",
                    image: "alpine:3.19",
                    command: [
                        "/bin/sh",
                        "-c",
                        command
                    ],
                    volumeMounts: [
                        {
                            name: "user-home",
                            mountPath: "/home",
                            subPath: `sites/${spec.slug}`
                        },
                        {
                            name: "backups",
                            mountPath: "/backups",
                            readOnly: true
                        }
                    ]
                }
            ],
            volumes: [
                {
                    name: "user-home",
                    persistentVolumeClaim: {
                        claimName: USER_HOME_PVC_NAME
                    }
                },
                {
                    name: "backups",
                    persistentVolumeClaim: {
                        claimName: USER_BACKUP_PVC_NAME
                    }
                }
            ]
        }
    };
}
