# Migration Mapping: Eski Path -> Yeni Path

Bu doküman, `infra/k8s/services/` yapısından yeni Kustomize yapısına geçiş için path mapping'lerini içerir.

## Base Resources

### Namespaces
| Eski Path | Yeni Path |
|-----------|-----------|
| `services/backup-system/namespace.yaml` | `base/namespaces/backup-system.yaml` |
| `services/cert-manager/cert-manager.yaml` (namespace içinde) | `base/namespaces/cert-manager.yaml` |
| `services/dns-zone/namespace.yaml` | `base/namespaces/dns-zone.yaml` |
| `services/flux-system/namespace.yaml` | `base/namespaces/flux-system.yaml` |
| `services/infra-db/namespace.yaml` | `base/namespaces/infra-db.yaml` |
| `services/kyverno/namespace.yaml` | `base/namespaces/kyverno.yaml` |
| `services/mail-zone/namespace.yaml` | `base/namespaces/mail-zone.yaml` |
| `services/platform/namespace.yaml` | `base/namespaces/platform.yaml` |

### Storage (PVCs)
| Eski Path | Yeni Path |
|-----------|-----------|
| `services/dns-zone/pvc.yaml` | `base/storage/dns-zone-pvc.yaml` |
| `services/infra-db/pvc.yaml` | `base/storage/infra-db-pvc.yaml` |
| `services/platform/pvc.yaml` | `base/storage/platform-pvc.yaml` |

### Ingress
| Eski Path | Yeni Path |
|-----------|-----------|
| `services/traefik/helmchartconfig-traefik.yaml` | `base/ingress/helmchartconfig-traefik.yaml` |
| `services/traefik/security-middlewares.yaml` | `base/ingress/security-middlewares.yaml` |

## Components

### cert-manager
| Eski Path | Yeni Path |
|-----------|-----------|
| `services/cert-manager/cert-manager.yaml` | `components/cert-manager/cert-manager.yaml` |
| `services/cert-manager/cluster-issuers.yaml` | `components/cert-manager/cluster-issuers.yaml` |

### kyverno
| Eski Path | Yeni Path |
|-----------|-----------|
| `services/kyverno/install.yaml` | `components/kyverno/install.yaml` |
| `services/kyverno/policies.yaml` | `components/kyverno/policies.yaml` |

### backup-system
| Eski Path | Yeni Path |
|-----------|-----------|
| `services/backup-system/backup-job-templates-configmap.yaml` | `components/backup-system/backup-job-templates-configmap.yaml` |
| `services/backup-system/backup-scripts-configmap.yaml` | `components/backup-system/backup-scripts-configmap.yaml` |
| `services/backup-system/backup-service-deploy.yaml` | `components/backup-system/backup-service-deploy.yaml` |
| `services/backup-system/backup-service-secret.yaml` | `components/backup-system/backup-service-secret.yaml` |
| `services/backup-system/backup-service-svc.yaml` | `components/backup-system/backup-service-svc.yaml` |
| `services/backup-system/rbac.yaml` | `components/backup-system/rbac.yaml` |
| `services/backup-system/serviceaccount.yaml` | `components/backup-system/serviceaccount.yaml` |

### dns-zone
| Eski Path | Yeni Path |
|-----------|-----------|
| `services/dns-zone/bind9.yaml` | `components/dns-zone/bind9.yaml` |
| `services/dns-zone/tsig-secret.yaml` | `components/dns-zone/tsig-secret.yaml` |
| `services/dns-zone/traefik-tcp/dns-routes.yaml` | `components/dns-zone/traefik-tcp/dns-routes.yaml` |

### infra-db
| Eski Path | Yeni Path |
|-----------|-----------|
| `services/infra-db/networkpolicy.yaml` | `components/infra-db/networkpolicy.yaml` |
| `services/infra-db/pgadmin-auth.yaml` | `components/infra-db/pgadmin-auth.yaml` |
| `services/infra-db/pgadmin-deploy.yaml` | `components/infra-db/pgadmin-deploy.yaml` |
| `services/infra-db/pgadmin-ingress.yaml` | `components/infra-db/pgadmin-ingress.yaml` |
| `services/infra-db/pgadmin-secret.yaml` | `components/infra-db/pgadmin-secret.yaml` |
| `services/infra-db/pgadmin-svc.yaml` | `components/infra-db/pgadmin-svc.yaml` |
| `services/infra-db/postgres-secret.yaml` | `components/infra-db/postgres-secret.yaml` |
| `services/infra-db/postgres-service.yaml` | `components/infra-db/postgres-service.yaml` |
| `services/infra-db/postgres-statefulset.yaml` | `components/infra-db/postgres-statefulset.yaml` |

### mail-zone
| Eski Path | Yeni Path |
|-----------|-----------|
| `services/mail-zone/mailcow-auth.yaml` | `components/mail-zone/mailcow-auth.yaml` |
| `services/mail-zone/mailcow-core.yaml` | `components/mail-zone/mailcow-core.yaml` |
| `services/mail-zone/mailcow-ingress.yaml` | `components/mail-zone/mailcow-ingress.yaml` |
| `services/mail-zone/networkpolicy.yaml` | `components/mail-zone/networkpolicy.yaml` |
| `services/mail-zone/traefik-tcp/ingressroutetcp.yaml` | `components/mail-zone/traefik-tcp/ingressroutetcp.yaml` |

### platform
| Eski Path | Yeni Path |
|-----------|-----------|
| `services/platform/controller-deploy.yaml` | `components/platform/controller-deploy.yaml` |
| `services/platform/controller-svc.yaml` | `components/platform/controller-svc.yaml` |
| `services/platform/panel-auth.yaml` | `components/platform/panel-auth.yaml` |
| `services/platform/panel-deploy.yaml` | `components/platform/panel-deploy.yaml` |
| `services/platform/panel-ingress.yaml` | `components/platform/panel-ingress.yaml` |
| `services/platform/panel-redirect.yaml` | `components/platform/panel-redirect.yaml` |
| `services/platform/panel-svc.yaml` | `components/platform/panel-svc.yaml` |
| `services/platform/rbac.yaml` | `components/platform/rbac.yaml` |

## Yeni Dosyalar

Aşağıdaki dosyalar yeni yapı için oluşturuldu:

- `base/kustomization.yaml` - Base resources'ları birleştirir
- `base/namespaces/kustomization.yaml` - Namespace'leri birleştirir
- `base/storage/kustomization.yaml` - PVC'leri birleştirir
- `base/ingress/kustomization.yaml` - Ingress kaynaklarını birleştirir
- `components/*/kustomization.yaml` - Her component için kustomization dosyası
- `overlays/prod/kustomization.yaml` - Production overlay
- `clusters/prod/kustomization.yaml` - Production cluster entry point
- `README-Infra.md` - Dokümantasyon
- `MIGRATION-MAPPING.md` - Bu dosya

## Davranış Değişikliği Yok

- Tüm kaynak adları aynı kaldı
- Tüm namespace'ler aynı kaldı
- Üretilen manifest çıktısı aynı (sadece organizasyon değişti)
- Kustomize ile toplanan kaynaklar, eski yapıdakiyle aynı
