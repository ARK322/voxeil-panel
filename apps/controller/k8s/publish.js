import { LABELS } from "./client.js";
export const APP_DEPLOYMENT_NAME = "app";
export const SERVICE_NAME = "web";
export const INGRESS_NAME = "web";
const DEFAULT_UPLOAD_DIRS = ["/app/public/uploads"];
function buildSelector(appName) {
    return {
        app: appName
    };
}
function resolveUploadDirs(uploadDirs) {
    const values = uploadDirs?.length ? uploadDirs : DEFAULT_UPLOAD_DIRS;
    const unique = new Set();
    for (const entry of values) {
        const trimmed = entry.trim();
        if (trimmed)
            unique.add(trimmed);
    }
    return unique.size > 0 ? Array.from(unique) : DEFAULT_UPLOAD_DIRS;
}
export function buildDeployment(spec) {
    const appName = spec.appName || `app-${spec.slug}`;
    const selector = buildSelector(appName);
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
                [LABELS.managedBy]: LABELS.managedBy
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
                            ...(spec.envSecretName ? {
                                envFrom: [{
                                    secretRef: {
                                        name: spec.envSecretName
                                    }
                                }]
                            } : {}),
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
export function buildService(spec) {
    const appName = spec.appName || `app-${spec.slug}`;
    const selector = buildSelector(appName);
    return {
        apiVersion: "v1",
        kind: "Service",
        metadata: {
            name: SERVICE_NAME,
            namespace: spec.namespace,
            labels: {
                [LABELS.managedBy]: LABELS.managedBy
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
export function buildIngress(spec) {
    const tlsEnabled = spec.tlsEnabled ?? false;
    const certIssuerName = spec.tlsIssuer ?? "letsencrypt-staging";
    const baseIngress = {
        apiVersion: "networking.k8s.io/v1",
        kind: "Ingress",
        metadata: {
            name: INGRESS_NAME,
            namespace: spec.namespace,
            labels: {
                [LABELS.managedBy]: LABELS.managedBy
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
