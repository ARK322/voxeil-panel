# Infrastructure Kubernetes Manifests

Bu dizin, Voxeil platformunun Kubernetes manifestlerini Kustomize base + overlays + clusters modeliyle organize eder.

## Yapı

```
infra/k8s/
├── base/                    # Temel kaynaklar (namespaces, storage, ingress)
│   ├── namespaces/         # Tüm namespace tanımları
│   ├── storage/            # PVC tanımları
│   └── ingress/            # Traefik konfigürasyonları
├── components/             # Yeniden kullanılabilir component'ler
│   ├── cert-manager/       # Cert-manager kurulumu ve cluster issuers
│   ├── kyverno/            # Kyverno kurulumu ve politikaları
│   ├── backup-system/      # Backup servisi
│   ├── dns-zone/           # DNS zone servisi (Bind9)
│   ├── infra-db/           # PostgreSQL ve pgAdmin
│   ├── mail-zone/          # Mailcow servisi
│   └── platform/           # Controller ve Panel
├── overlays/                # Ortam-spesifik overlay'ler
│   └── prod/               # Production overlay
│       ├── kustomization.yaml
│       └── patches/        # Ortam-spesifik patch'ler
└── clusters/                # Cluster-spesifik konfigürasyonlar
    └── prod/               # Production cluster
        └── kustomization.yaml
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

### Diff alma:
```bash
kustomize build infra/k8s/clusters/prod | kubectl diff -f -
```

## Organizasyon Mantığı

- **base/**: Tüm ortamlarda ortak olan temel kaynaklar
  - Namespaces: Tüm namespace tanımları merkezi olarak yönetilir
  - Storage: PVC tanımları storage klasöründe toplanır
  - Ingress: Traefik konfigürasyonları ingress klasöründe

- **components/**: Bağımsız olarak yönetilebilen servisler
  - Her component kendi kustomization.yaml dosyasına sahip
  - Component'ler overlay'lerde seçilerek kullanılır

- **overlays/**: Ortam-spesifik konfigürasyonlar
  - Base ve seçili component'leri birleştirir
  - Ortam-spesifik patch'ler burada tanımlanır

- **clusters/**: Cluster-spesifik entry point'ler
  - Tek bir `kustomize build` komutuyla tüm manifestler üretilir

## Notlar

- Eski `services/` dizini hala mevcut (backward compatibility için)
- Yeni yapıya geçiş tamamlandığında `services/` dizini kaldırılabilir
- Tüm kaynak adları ve namespace'ler değişmedi (davranış korundu)
