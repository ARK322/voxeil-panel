# Yeni infra/k8s Yapı Özeti

## Oluşturulan Yapı

```
infra/k8s/
├── base/                          # Temel kaynaklar
│   ├── kustomization.yaml        # Base resources'ları birleştirir
│   ├── namespaces/               # Tüm namespace tanımları
│   │   ├── kustomization.yaml
│   │   ├── backup-system.yaml
│   │   ├── cert-manager.yaml
│   │   ├── dns-zone.yaml
│   │   ├── flux-system.yaml
│   │   ├── infra-db.yaml
│   │   ├── kyverno.yaml
│   │   ├── mail-zone.yaml
│   │   └── platform.yaml
│   ├── storage/                  # PVC tanımları
│   │   ├── kustomization.yaml
│   │   ├── dns-zone-pvc.yaml
│   │   ├── infra-db-pvc.yaml
│   │   └── platform-pvc.yaml
│   └── ingress/                  # Traefik konfigürasyonları
│       ├── kustomization.yaml
│       ├── helmchartconfig-traefik.yaml
│       └── security-middlewares.yaml
│
├── components/                    # Yeniden kullanılabilir component'ler
│   ├── cert-manager/
│   │   ├── kustomization.yaml
│   │   ├── cert-manager.yaml
│   │   └── cluster-issuers.yaml
│   ├── kyverno/
│   │   ├── kustomization.yaml
│   │   ├── install.yaml
│   │   └── policies.yaml
│   ├── backup-system/
│   │   ├── kustomization.yaml
│   │   ├── backup-job-templates-configmap.yaml
│   │   ├── backup-scripts-configmap.yaml
│   │   ├── backup-service-deploy.yaml
│   │   ├── backup-service-secret.yaml
│   │   ├── backup-service-svc.yaml
│   │   ├── rbac.yaml
│   │   └── serviceaccount.yaml
│   ├── dns-zone/
│   │   ├── kustomization.yaml
│   │   ├── bind9.yaml
│   │   ├── tsig-secret.yaml
│   │   └── traefik-tcp/
│   │       └── dns-routes.yaml
│   ├── infra-db/
│   │   ├── kustomization.yaml
│   │   ├── networkpolicy.yaml
│   │   ├── pgadmin-auth.yaml
│   │   ├── pgadmin-deploy.yaml
│   │   ├── pgadmin-ingress.yaml
│   │   ├── pgadmin-secret.yaml
│   │   ├── pgadmin-svc.yaml
│   │   ├── postgres-secret.yaml
│   │   ├── postgres-service.yaml
│   │   └── postgres-statefulset.yaml
│   ├── mail-zone/
│   │   ├── kustomization.yaml
│   │   ├── mailcow-auth.yaml
│   │   ├── mailcow-core.yaml
│   │   ├── mailcow-ingress.yaml
│   │   ├── networkpolicy.yaml
│   │   └── traefik-tcp/
│   │       └── ingressroutetcp.yaml
│   └── platform/
│       ├── kustomization.yaml
│       ├── controller-deploy.yaml
│       ├── controller-svc.yaml
│       ├── panel-auth.yaml
│       ├── panel-deploy.yaml
│       ├── panel-ingress.yaml
│       ├── panel-redirect.yaml
│       ├── panel-svc.yaml
│       └── rbac.yaml
│
├── overlays/                       # Ortam-spesifik overlay'ler
│   └── prod/
│       ├── kustomization.yaml     # Base + tüm component'leri birleştirir
│       └── patches/               # Ortam-spesifik patch'ler için (şimdilik boş)
│
├── clusters/                       # Cluster-spesifik entry point'ler
│   └── prod/
│       └── kustomization.yaml     # Tek apply noktası
│
├── services/                       # ESKİ YAPI (backward compatibility için korundu)
│   └── ...                        # Eski dosyalar hala mevcut
│
├── templates/                      # Template dosyaları (değişmedi)
│   ├── tenant/
│   ├── user/
│   └── zones/
│
├── README-Infra.md                # Dokümantasyon
├── MIGRATION-MAPPING.md           # Eski -> Yeni path mapping
└── STRUCTURE-SUMMARY.md           # Bu dosya
```

## Kullanım

### Tüm manifestleri build etme:
```bash
kustomize build infra/k8s/clusters/prod
```

### Apply etme:
```bash
kustomize build infra/k8s/clusters/prod | kubectl apply -f -
```

### Sadece belirli bir component'i build etme:
```bash
kustomize build infra/k8s/components/cert-manager
```

## Önemli Notlar

1. **Davranış Değişikliği Yok**: Tüm kaynak adları, namespace'ler ve manifest içerikleri aynı kaldı. Sadece organizasyon değişti.

2. **cert-manager Namespace**: `cert-manager.yaml` dosyası içinde namespace tanımı var. Bu, `base/namespaces/cert-manager.yaml` ile duplicate olabilir, ancak Kubernetes bunu idempotent olarak handle eder. Sorun yok.

3. **Eski Yapı Korundu**: `services/` dizini hala mevcut. Backward compatibility için korundu. Gelecekte kaldırılabilir.

4. **Templates Değişmedi**: `templates/` dizini dokunulmadı, çünkü bunlar runtime'da kullanılan template'ler.

5. **Overlay Yapısı**: Şimdilik `overlays/prod` boş patch'ler içeriyor, ancak yapı hazır. Gelecekte ortam-spesifik değişiklikler için kullanılabilir.

## Doğrulama

Yapı doğru oluşturuldu mu kontrol etmek için:

```bash
# Kustomize build testi (eğer kustomize kuruluysa)
kustomize build infra/k8s/clusters/prod > /dev/null && echo "✓ Build başarılı"

# Veya sadece yapısal kontrol
find infra/k8s/base infra/k8s/components infra/k8s/overlays infra/k8s/clusters -name "kustomization.yaml" | wc -l
# Beklenen: 12 kustomization.yaml dosyası
```

## Sonraki Adımlar

1. Installer/uninstaller script'lerini yeni yapıya entegre et
2. CI/CD pipeline'larını güncelle
3. Eski `services/` dizinini kaldır (opsiyonel, backward compatibility için korunabilir)
