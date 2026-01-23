import { LABELS } from "./client.js";
import { USER_HOME_PVC_NAME } from "./pvc.js";
// Names are now dynamic: *-<siteSlug>
export function getDeploymentName(slug) {
    return `app-${slug}`;
}
export function getServiceName(slug) {
    return `web-${slug}`;
}
export function getIngressName(slug) {
    return `web-${slug}`;
}
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
    const deploymentName = getDeploymentName(spec.slug);
    const labels = {
        [LABELS.managedBy]: LABELS.managedBy,
        [LABELS.siteSlug]: spec.slug,
        "voxeil.io/site": "true"
    };
    if (spec.userId) {
        labels["voxeil.io/user-id"] = spec.userId;
    }
    return {
        apiVersion: "apps/v1",
        kind: "Deployment",
        metadata: {
            name: deploymentName,
            namespace: spec.namespace,
            labels
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
                    volumes: [
                        {
                            name: "user-home",
                            persistentVolumeClaim: {
                                claimName: USER_HOME_PVC_NAME
                            }
                        }
                    ],
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
                            volumeMounts: [
                                {
                                    name: "user-home",
                                    mountPath: "/home",
                                    subPath: `sites/${spec.slug}`
                                }
                            ],
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
    const serviceName = getServiceName(spec.slug);
    const labels = {
        [LABELS.managedBy]: LABELS.managedBy,
        [LABELS.siteSlug]: spec.slug,
        "voxeil.io/site": "true"
    };
    if (spec.userId) {
        labels["voxeil.io/user-id"] = spec.userId;
    }
    return {
        apiVersion: "v1",
        kind: "Service",
        metadata: {
            name: serviceName,
            namespace: spec.namespace,
            labels
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
    const ingressName = getIngressName(spec.slug);
    const serviceName = getServiceName(spec.slug);
    const labels = {
        [LABELS.managedBy]: LABELS.managedBy,
        [LABELS.siteSlug]: spec.slug,
        "voxeil.io/site": "true"
    };
    if (spec.userId) {
        labels["voxeil.io/user-id"] = spec.userId;
    }
    const baseIngress = {
        apiVersion: "networking.k8s.io/v1",
        kind: "Ingress",
        metadata: {
            name: ingressName,
            namespace: spec.namespace,
            labels
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
                                        name: serviceName,
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
