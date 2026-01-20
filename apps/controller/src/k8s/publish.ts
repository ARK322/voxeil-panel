import type { V1Deployment, V1Ingress, V1Service } from "@kubernetes/client-node";
import { LABELS } from "./client.js";
import { TENANT_PVC_NAME } from "./pvc.js";

export const APP_DEPLOYMENT_NAME = "app";
export const SERVICE_NAME = "web";
export const INGRESS_NAME = "web";
const DEFAULT_UPLOAD_DIRS = ["/app/public/uploads"];

type PublishSpec = {
  namespace: string;
  slug: string;
  image: string;
  containerPort: number;
  cpu: number;
  ramGi: number;
  host: string;
  tlsEnabled?: boolean;
  tlsIssuer?: string;
  imagePullSecretName?: string;
  uploadDirs?: string[];
};

function buildSelector(slug: string): Record<string, string> {
  return {
    app: "web",
    [LABELS.siteSlug]: slug
  };
}

function resolveUploadDirs(uploadDirs?: string[]): string[] {
  const values = uploadDirs?.length ? uploadDirs : DEFAULT_UPLOAD_DIRS;
  const unique = new Set<string>();
  for (const entry of values) {
    const trimmed = entry.trim();
    if (trimmed) unique.add(trimmed);
  }
  return unique.size > 0 ? Array.from(unique) : DEFAULT_UPLOAD_DIRS;
}

export function buildDeployment(spec: PublishSpec): V1Deployment {
  const selector = buildSelector(spec.slug);
  const imagePullSecrets = spec.imagePullSecretName
    ? [{ name: spec.imagePullSecretName }]
    : undefined;
  const uploadDirs = resolveUploadDirs(spec.uploadDirs);
  return {
    apiVersion: "apps/v1",
    kind: "Deployment",
    metadata: {
      name: APP_DEPLOYMENT_NAME,
      namespace: spec.namespace,
      labels: {
        [LABELS.managedBy]: LABELS.managedBy,
        [LABELS.siteSlug]: spec.slug
      }
    },
    spec: {
      replicas: 1,
      selector: {
        matchLabels: selector
      },
      template: {
        metadata: {
          labels: {
            ...selector,
            [LABELS.managedBy]: LABELS.managedBy
          }
        },
        spec: {
          ...(imagePullSecrets ? { imagePullSecrets } : {}),
          containers: [
            {
              name: "app",
              image: spec.image,
              ports: [{ containerPort: spec.containerPort }],
              volumeMounts: uploadDirs.map((mountPath) => ({
                name: TENANT_PVC_NAME,
                mountPath
              })),
              resources: {
                requests: {
                  cpu: String(spec.cpu),
                  memory: `${spec.ramGi}Gi`
                },
                limits: {
                  cpu: String(spec.cpu),
                  memory: `${spec.ramGi}Gi`
                }
              }
            }
          ],
          volumes: [
            {
              name: TENANT_PVC_NAME,
              persistentVolumeClaim: {
                claimName: TENANT_PVC_NAME
              }
            }
          ]
        }
      }
    }
  };
}

export function buildService(spec: PublishSpec): V1Service {
  const selector = buildSelector(spec.slug);
  return {
    apiVersion: "v1",
    kind: "Service",
    metadata: {
      name: SERVICE_NAME,
      namespace: spec.namespace,
      labels: {
        [LABELS.managedBy]: LABELS.managedBy,
        [LABELS.siteSlug]: spec.slug
      }
    },
    spec: {
      type: "ClusterIP",
      selector,
      ports: [
        {
          name: "http",
          port: 80,
          targetPort: spec.containerPort,
          protocol: "TCP"
        }
      ]
    }
  };
}

export function buildIngress(spec: PublishSpec): V1Ingress {
  const tlsEnabled = spec.tlsEnabled ?? false;
  const certIssuerName = spec.tlsIssuer ?? "letsencrypt-staging";
  const baseIngress: V1Ingress = {
    apiVersion: "networking.k8s.io/v1",
    kind: "Ingress",
    metadata: {
      name: INGRESS_NAME,
      namespace: spec.namespace,
      labels: {
        [LABELS.managedBy]: LABELS.managedBy,
        [LABELS.siteSlug]: spec.slug
      }
    },
    spec: {
      ingressClassName: process.env.INGRESS_CLASS_NAME ?? "traefik",
      rules: [
        {
          host: spec.host,
          http: {
            paths: [
              {
                path: "/",
                pathType: "Prefix",
                backend: {
                  service: {
                    name: SERVICE_NAME,
                    port: { number: 80 }
                  }
                }
              }
            ]
          }
        }
      ],
      ...(tlsEnabled
        ? {
            tls: [
              {
                hosts: [spec.host],
                secretName: `tls-${spec.slug}`
              }
            ]
          }
        : {})
    }
  };

  return {
    ...baseIngress,
    metadata: {
      ...baseIngress.metadata,
      annotations: {
        ...(baseIngress.metadata?.annotations ?? {}),
        "traefik.ingress.kubernetes.io/router.entrypoints": tlsEnabled
          ? "websecure"
          : "web",
        "traefik.ingress.kubernetes.io/router.tls": tlsEnabled
          ? "true"
          : "false",
        ...(tlsEnabled
          ? { "cert-manager.io/cluster-issuer": certIssuerName }
          : {})
      }
    }
  };
}
