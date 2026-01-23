import { promises as fs } from "node:fs";
import path from "node:path";
import { LABELS } from "../k8s/client.js";
import { USER_HOME_PVC_NAME } from "../k8s/pvc.js";
export async function listLatestBackup(dir) {
    try {
        const entries = await fs.readdir(dir, { withFileTypes: true });
        const candidates = await Promise.all(entries
            .filter((entry) => entry.isFile() && entry.name !== "SKIPPED.txt" && !entry.name.endsWith(".txt"))
            .map(async (entry) => {
            const fullPath = path.join(dir, entry.name);
            const stat = await fs.stat(fullPath);
            return { name: entry.name, mtimeMs: stat.mtimeMs };
        }));
        if (candidates.length === 0)
            return null;
        candidates.sort((a, b) => b.mtimeMs - a.mtimeMs);
        return candidates[0]?.name ?? null;
    }
    catch (error) {
        if (error?.code === "ENOENT")
            return null;
        throw error;
    }
}
export function buildRestorePod(spec) {
    const command = spec.archivePath.endsWith(".tar.zst")
        ? `apk add --no-cache zstd >/dev/null && rm -rf /home/* /home/.[!.]* /home/..?* && tar --use-compress-program=zstd -xf ${spec.archivePath} -C /home`
        : `apk add --no-cache gzip >/dev/null && rm -rf /home/* /home/.[!.]* /home/..?* && tar -xzf ${spec.archivePath} -C /home`;
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
                    hostPath: {
                        path: "/backups",
                        type: "DirectoryOrCreate"
                    }
                }
            ]
        }
    };
}
