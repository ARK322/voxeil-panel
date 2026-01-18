import type { V1Deployment, V1Ingress, V1Service } from "@kubernetes/client-node";
import { LABELS } from "./client.js";
import { GHCR_PULL_SECRET_NAME } from "./secrets.js";

export const APP_DEPLOYMENT_NAME = "app";
export const SERVICE_NAME = "web";
export const INGRESS_NAME = "web";

type PublishSpec = {
  namespace: string;
  slug: string;
  image: string;
  containerPort: number;
  cpu: number;
  ramGi: number;
  host: string;
};

function buildSelector(slug: string): Record<string, string> {
  return {
    app: "web",
    [LABELS.siteSlug]: slug
  };
}

export function buildDeployment(spec: PublishSpec): V1Deployment {
  const selector = buildSelector(spec.slug);
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
          imagePullSecrets: [{ name: GHCR_PULL_SECRET_NAME }],
          containers: [
            {
              name: "app",
              image: spec.image,
              ports: [{ containerPort: spec.containerPort }],
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
      ]
    }
  };

  return {
    ...baseIngress,
    metadata: {
      ...baseIngress.metadata,
      annotations: {
        ...(baseIngress.metadata?.annotations ?? {}),
        "traefik.ingress.kubernetes.io/router.entrypoints": "web",
        "traefik.ingress.kubernetes.io/router.tls": "false"
      }
    }
  };
}
