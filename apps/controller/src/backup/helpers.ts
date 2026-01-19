import type { V1Pod } from "@kubernetes/client-node";
import { promises as fs } from "node:fs";
import path from "node:path";
import { LABELS } from "../k8s/client.js";

export async function listLatestBackup(dir: string): Promise<string | null> {
  try {
    const entries = await fs.readdir(dir, { withFileTypes: true });
    const candidates = await Promise.all(
      entries
        .filter((entry) => entry.isFile() && entry.name !== "SKIPPED.txt" && !entry.name.endsWith(".txt"))
        .map(async (entry) => {
          const fullPath = path.join(dir, entry.name);
          const stat = await fs.stat(fullPath);
          return { name: entry.name, mtimeMs: stat.mtimeMs };
        })
    );
    if (candidates.length === 0) return null;
    candidates.sort((a, b) => b.mtimeMs - a.mtimeMs);
    return candidates[0]?.name ?? null;
  } catch (error: any) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

type RestorePodSpec = {
  name: string;
  namespace: string;
  slug: string;
  archivePath: string;
};

export function buildRestorePod(spec: RestorePodSpec): V1Pod {
  const command = spec.archivePath.endsWith(".tar.zst")
    ? `apk add --no-cache zstd >/dev/null && rm -rf /data/* /data/.[!.]* /data/..?* && tar --use-compress-program=zstd -xf ${spec.archivePath} -C /data`
    : `apk add --no-cache gzip >/dev/null && rm -rf /data/* /data/.[!.]* /data/..?* && tar -xzf ${spec.archivePath} -C /data`;
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
              name: "site-data",
              mountPath: "/data"
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
          name: "site-data",
          persistentVolumeClaim: {
            claimName: "site-data"
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
