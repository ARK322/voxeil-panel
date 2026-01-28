# Apps Modülerleştirme Özeti

## Yapılan Değişiklikler

### A) Monorepo Yapısı

#### 1. Root Package.json
- ✅ `package.json` oluşturuldu
- ✅ npm workspaces yapılandırıldı (`apps/*`, `packages/*`)

#### 2. Packages Oluşturuldu

**packages/shared/**
- Ortak TypeScript tipleri (`types.ts`)
- Runtime-bağımsız tipler (HealthStatus, Tenant, Site, MailInfo, DbInfo, DnsInfo, BackupInfo, vb.)
- Zod bağımlılığı (gelecekte ortak DTO validation için hazır)

**packages/api-client/**
- Panel'in controller'a konuştuğu typed client
- Token getter pattern ile server/client uyumlu
- Tüm controller API fonksiyonlarını kapsar

### B) Apps Güncellemeleri

#### apps/controller
- ✅ `package.json` workspace bağımlılıkları eklendi (gerekirse)
- ✅ Dockerfile workspace install desteği eklendi
- ✅ Deploy yapısı oluşturuldu (`apps/controller/deploy/`)

#### apps/panel
- ✅ `package.json` workspace bağımlılıkları eklendi (`@voxeil/shared`, `@voxeil/api-client`)
- ✅ `app/lib/controller.ts` api-client paketini kullanacak şekilde refactor edildi
- ✅ `src/lib/types.ts` shared paketinden re-export yapıyor
- ✅ Dockerfile workspace install desteği eklendi
- ✅ Deploy yapısı oluşturuldu (`apps/panel/deploy/`)

### C) Deploy Yapısı

#### apps/controller/deploy/
```
base/
  - kustomization.yaml
  - deployment.yaml
  - service.yaml
overlays/
  prod/
    - kustomization.yaml
```

#### apps/panel/deploy/
```
base/
  - kustomization.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
  - auth.yaml
  - redirect.yaml
overlays/
  prod/
    - kustomization.yaml
    - ingress-patch.yaml
```

#### apps/deploy/clusters/
```
prod/
  - kustomization.yaml  # controller + panel overlay'lerini include eder
```

### D) Dockerfile Güncellemeleri

#### apps/controller/Dockerfile
- Workspace-aware install eklendi
- Root package.json ve packages/ kopyalanıyor
- `npm install --workspace=apps/controller` kullanılıyor
- **Davranış değişmedi**: Port 8080, CMD aynı

#### apps/panel/Dockerfile
- Workspace-aware install eklendi
- Root package.json ve packages/ kopyalanıyor
- `npm install --workspace=apps/panel` kullanılıyor
- **Davranış değişmedi**: Port 3000, CMD aynı

## Taşınan Dosyalar

### Ortak Kodlar → packages/

| Eski Konum | Yeni Konum | Not |
|------------|------------|-----|
| `apps/panel/src/lib/types.ts` | `packages/shared/src/types.ts` | Re-export ile backward compatibility korundu |
| `apps/panel/app/lib/controller.ts` | `packages/api-client/src/index.ts` | Wrapper ile backward compatibility korundu |

### K8s Manifestleri → apps/*/deploy/

| Eski Konum | Yeni Konum |
|------------|------------|
| `infra/k8s/services/platform/controller-deploy.yaml` | `apps/controller/deploy/base/deployment.yaml` |
| `infra/k8s/services/platform/controller-svc.yaml` | `apps/controller/deploy/base/service.yaml` |
| `infra/k8s/services/platform/panel-deploy.yaml` | `apps/panel/deploy/base/deployment.yaml` |
| `infra/k8s/services/platform/panel-svc.yaml` | `apps/panel/deploy/base/service.yaml` |
| `infra/k8s/services/platform/panel-ingress.yaml` | `apps/panel/deploy/base/ingress.yaml` |
| `infra/k8s/services/platform/panel-auth.yaml` | `apps/panel/deploy/base/auth.yaml` |
| `infra/k8s/services/platform/panel-redirect.yaml` | `apps/panel/deploy/base/redirect.yaml` |

**NOT**: Eski manifestler `infra/k8s/services/platform/` altında kaldı. Installer entegrasyonu sonrası kaldırılabilir.

## Davranış Değişikliği Kanıtları

### ✅ API Path'ler
- Değişmedi: Tüm API endpoint'leri aynı (`/sites`, `/users`, `/auth`, vb.)

### ✅ Environment Variables
- Controller: `PORT`, `ALLOWLIST_PATH`, `ADMIN_API_KEY`, `JWT_SECRET`, vb. - **HEPSİ AYNI**
- Panel: `CONTROLLER_BASE_URL` - **AYNI**

### ✅ Portlar
- Controller: `8080` - **AYNI**
- Panel: `3000` - **AYNI**

### ✅ K8s Resource İsimleri
- Controller: `controller` (deployment, service) - **AYNI**
- Panel: `panel` (deployment, service, ingress) - **AYNI**

### ✅ Namespace
- Her ikisi de `platform` namespace - **AYNI**

### ✅ Image İsimleri
- Dockerfile'larda placeholder'lar aynı (`REPLACE_CONTROLLER_IMAGE`, `REPLACE_PANEL_IMAGE`)
- Image tag/registry isimleri değişmedi

## Yeni Klasör Yapısı (Kısaltılmış)

```
voxeil-panel/
├── package.json                    # Root workspace config
├── apps/
│   ├── controller/
│   │   ├── package.json
│   │   ├── Dockerfile
│   │   ├── deploy/
│   │   │   ├── base/
│   │   │   │   ├── kustomization.yaml
│   │   │   │   ├── deployment.yaml
│   │   │   │   └── service.yaml
│   │   │   └── overlays/
│   │   │       └── prod/
│   │   │           └── kustomization.yaml
│   │   └── [diğer dosyalar]
│   ├── panel/
│   │   ├── package.json
│   │   ├── Dockerfile
│   │   ├── deploy/
│   │   │   ├── base/
│   │   │   │   ├── kustomization.yaml
│   │   │   │   ├── deployment.yaml
│   │   │   │   ├── service.yaml
│   │   │   │   ├── ingress.yaml
│   │   │   │   ├── auth.yaml
│   │   │   │   └── redirect.yaml
│   │   │   └── overlays/
│   │   │       └── prod/
│   │   │           ├── kustomization.yaml
│   │   │           └── ingress-patch.yaml
│   │   └── [diğer dosyalar]
│   └── deploy/
│       └── clusters/
│           └── prod/
│               └── kustomization.yaml
└── packages/
    ├── shared/
    │   ├── package.json
    │   ├── tsconfig.json
    │   └── src/
    │       ├── index.ts
    │       └── types.ts
    └── api-client/
        ├── package.json
        ├── tsconfig.json
        └── src/
            └── index.ts
```

## Doğrulama Adımları

### 1. Workspace Install
```bash
npm install
```

### 2. Typecheck
```bash
npm run typecheck --workspace=packages/shared
npm run typecheck --workspace=packages/api-client
npm run typecheck --workspace=apps/panel  # Next.js typecheck
```

### 3. Build Test
```bash
npm run build --workspace=apps/panel
npm run build --workspace=packages/shared
npm run build --workspace=packages/api-client
```

### 4. Kustomize Build Test
```bash
kubectl kustomize apps/controller/deploy/base
kubectl kustomize apps/panel/deploy/base
kubectl kustomize apps/deploy/clusters/prod
```

### 5. Docker Build Test
```bash
# Controller
docker build -f apps/controller/Dockerfile -t test-controller .

# Panel
docker build -f apps/panel/Dockerfile -t test-panel .
```

## Sonraki Adımlar (Önerilen)

1. **Installer Entegrasyonu**: `apps/deploy/clusters/prod` kullanılacak şekilde installer güncellenebilir
2. **Eski Manifest Temizliği**: `infra/k8s/services/platform/` altındaki eski manifestler kaldırılabilir (installer entegrasyonu sonrası)
3. **CI/CD Güncellemesi**: Docker build komutları workspace-aware olacak şekilde güncellenebilir
4. **Documentation**: README güncellemesi (kullanıcı talep ederse)

## Notlar

- ✅ Backward compatibility korundu (panel'deki import'lar çalışmaya devam ediyor)
- ✅ Runtime davranışı değişmedi
- ✅ K8s resource isimleri, namespace'ler, portlar aynı
- ✅ Environment variable isimleri aynı
- ✅ Image isimleri/placeholder'ları aynı
- ⚠️ Eski `infra/k8s/services/platform/` manifestleri henüz kaldırılmadı (installer uyumluluğu için)
