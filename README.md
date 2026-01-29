# Voxeil Panel

K3s/Kubernetes tabanlı hosting panel altyapısı. Tek entrypoint script (`voxeil.sh`) ile kurulum, kaldırma ve yönetim işlemleri yapılır. Modüler faz-bazlı yapı ile güvenli ve izlenebilir operasyonlar sağlar.

## Hızlı Başlangıç

```bash
# Script'i indir ve çalıştır
curl -fL -o /tmp/voxeil.sh https://raw.githubusercontent.com/ARK322/voxeil-panel/main/voxeil.sh
bash /tmp/voxeil.sh install

# Durum kontrolü
bash /tmp/voxeil.sh doctor

# Güvenli kaldırma
bash /tmp/voxeil.sh uninstall --force

# Node temizleme (geri dönüşsüz)
bash /tmp/voxeil.sh purge-node --force

# Nuke (purge-node alias'ı)
bash /tmp/voxeil.sh nuke --force
```

## Komutlar

### `voxeil.sh install`

Voxeil Panel'i kurar. K3s kurulumu, core servisler ve uygulamaları sıralı fazlar halinde yükler.

**Örnek kullanım:**
```bash
bash /tmp/voxeil.sh install
```

**Güvenlik notu:** Kurulum root yetkisi gerektirir. Doğru VPS'de çalıştırdığınızdan emin olun.

### `voxeil.sh uninstall`

Voxeil Panel'i güvenli şekilde kaldırır. Yalnızca Voxeil kaynaklarını siler, sistem dosyalarına dokunmaz.

**Örnek kullanım:**
```bash
bash /tmp/voxeil.sh uninstall --force
```

**Güvenlik notu:** `--force` bayrağı gereklidir.

### `voxeil.sh purge-node --force`

Node'u tamamen temizler. k3s'i kaldırır, runtime dosyalarını siler ve sistemi sıfırlar.

**Örnek kullanım:**
```bash
bash /tmp/voxeil.sh purge-node --force
```

**Güvenlik notu:** **GERİ DÖNÜŞSÜZDÜR.** `--force` bayrağı zorunludur. Tüm k3s ve Kubernetes kaynakları kalıcı olarak silinir. Doğru node'da çalıştırdığınızdan emin olun.

### `voxeil.sh nuke --force`

`purge-node --force` komutunun alias'ıdır. Aynı işlevi görür.

**Örnek kullanım:**
```bash
bash /tmp/voxeil.sh nuke --force
```

**Güvenlik notu:** `purge-node` ile aynı uyarılar geçerlidir. Geri dönüşsüz işlemdir.

### `voxeil.sh doctor`

Kurulum durumunu kontrol eder. Read-only modda çalışır, hiçbir değişiklik yapmaz.

**Örnek kullanım:**
```bash
bash /tmp/voxeil.sh doctor
```

**Exit code anlamları:**
- `0`: PASS - Kritik sorun yok
- `1`: FAIL - Kritik sorun var
- `2`: UNABLE_TO_CHECK - kubectl/cluster erişilemiyor

**Prod gate:** Production'a çıkmadan önce `doctor` komutunun `exit code 0` döndürmesi gerekir.

## Ephemeral Yapı

`voxeil.sh` script'i `/tmp/voxeil.sh` konumuna indirilir ve çalıştırılır. Bu script dosyasını silmek sistemi etkilemez çünkü:

- Script dosyası yalnızca dispatcher görevi görür
- Asıl sistem kaynakları k3s/Kubernetes cluster'ında kurulur
- `uninstall` veya `nuke` komutları script dosyasını otomatik silmez (zaten `/tmp` dizininde, sistem temizliğinde otomatik silinir)

**Önemli:** Script dosyasını silmek kurulu sistemi etkilemez, ancak kurulu k3s/k8s kaynaklarını silmek sistemi etkiler.

## Repo Yapısı

```
voxeil-panel/
├── voxeil.sh              # Ana entrypoint (dispatcher + archive download/extract)
├── cmd/                   # Orchestrator script'leri
│   ├── install.sh        # Install orchestrator
│   ├── uninstall.sh      # Uninstall orchestrator
│   ├── purge-node.sh     # Purge-node orchestrator
│   └── doctor.sh         # Doctor orchestrator
├── phases/                # Faz script'leri (sıralı çalışır)
│   ├── install/          # Install fazları (00-preflight, 10-k3s, 20-core, 30-apps, 90-postcheck)
│   ├── uninstall/        # Uninstall fazları (00-preflight, 20-remove-apps, 30-remove-infra, 80-clean-namespaces, 90-postcheck)
│   ├── purge-node/       # Purge-node fazları (00-confirm, 20-k3s-uninstall, 30-runtime-clean, 90-final)
│   └── doctor/           # Doctor fazları (00-env, 10-cluster, 20-health, 30-leftovers, 90-summary)
├── lib/                   # Ortak helper script'leri
│   ├── common.sh         # Logging, error handling, state registry
│   ├── validate.sh       # Validation helpers
│   ├── kube.sh           # Kubernetes helpers
│   └── ...
└── tools/                 # CI/ops script'leri (prod kurulumun parçası değil)
    ├── ci/               # CI script'leri
    └── ops/              # Ops script'leri
```

**Not:** `scripts/` klasörü artık yok (taşındı). Eski wrapper'lar (`installer/`, `uninstaller/`, `nuke/`) kaldırıldı.

## Phase Sistemi

Her komut (`install`, `uninstall`, `purge-node`, `doctor`) kendi faz dizinindeki script'leri sıralı olarak çalıştırır:

1. **Orchestrator** (`cmd/*.sh`): Faz dizinindeki tüm `.sh` dosyalarını alfabetik sırayla bulur ve çalıştırır
2. **Faz script'leri**: Her faz `set -Eeuo pipefail` ile çalışır (hata durumunda durur)
3. **Ortak kütüphane**: Tüm fazlar `lib/common.sh`'i source eder (logging, error handling, state registry)
4. **Hata yönetimi**: Bir faz başarısız olursa, orchestrator hangi fazda patladığını gösterir ve durur

**Örnek akış:**
```bash
# install komutu çalıştırıldığında:
cmd/install.sh → phases/install/00-preflight.sh → 10-k3s.sh → 20-core.sh → 30-apps.sh → 90-postcheck.sh
```

## Doctor = Prod Gate

`doctor` komutu Production'a çıkmadan önce sistem durumunu kontrol eder:

- **Read-only:** Hiçbir değişiklik yapmaz, yalnızca kontrol eder
- **Exit code'lar:**
  - `0`: Sistem temiz, kritik sorun yok
  - `1`: Kritik sorun var (ör. leftover kaynaklar)
  - `2`: Kontrol edilemedi (kubectl/cluster erişilemiyor)
- **Kullanım:** CI/CD pipeline'larında veya manuel kontrol için kullanılır

**Prod çıkış öncesi:**
```bash
bash /tmp/voxeil.sh doctor
if [ $? -eq 0 ]; then
  echo "Sistem hazır, prod'a çıkılabilir"
else
  echo "Sorunlar var, prod'a çıkma!"
  exit 1
fi
```

## State Management

Voxeil Panel uses a state file (`/var/lib/voxeil/state.env`) to store generated secrets and configuration values between install runs. This ensures:

- **Idempotency**: Re-running `install` reuses existing secrets instead of generating new ones
- **Consistency**: Same secrets are used across install/uninstall cycles
- **Security**: Secret values are stored with restricted permissions (600)

**What is stored:**
- Generated API keys and JWT secrets
- Database passwords and connection strings
- Admin credentials (username, password, email)
- Service configuration values (ports, URLs, etc.)

**Resetting state:**
To force regeneration of all secrets, delete the state file:
```bash
rm -f /var/lib/voxeil/state.env
```

**Note:** Deleting the state file will cause new secrets to be generated on the next install, which may break existing deployments if they depend on the old secrets.

## Güvenlik / Dikkat

### Kritik Komutlar

**`purge-node` ve `nuke` komutları geri dönüşsüzdür:**
- Tüm k3s kurulumunu kaldırır
- Kubernetes kaynaklarını siler
- Runtime dosyalarını temizler
- **`--force` bayrağı olmadan çalışmaz** (güvenlik kontrolü)

**Kurallar:**
- `--force` bayrağı olmadan `purge-node` çalışmaz
- Doğru VPS/node'da çalıştırdığınızdan emin olun
- Production sistemlerde dikkatli kullanın

### Genel Güvenlik

- Tüm komutlar root yetkisi gerektirebilir
- Script'ler `set -Eeuo pipefail` ile çalışır (hata durumunda durur)
- State registry (varsa) kurulum durumunu takip eder

## CI / Validations

- **Syntax check:** Linux'ta `bash -n` ile script syntax kontrolü yapılır
- **Workflow validations:** GitHub Actions workflow'larında otomatik syntax ve lint kontrolleri mevcuttur
- **Phase validation:** Her faz script'i çalıştırılmadan önce executable yapılır

## Eski Wrapper'lar Kaldırıldı

Aşağıdaki klasörler ve script'ler artık yok:
- `installer/` klasörü
- `uninstaller/` klasörü
- `nuke/` klasörü
- `scripts/` klasörü (taşındı)

**Doğru kullanım:**
- `voxeil.sh` (ana entrypoint, önerilen kullanım)
- `cmd/*.sh` genellikle `voxeil.sh` tarafından çağrılır; doğrudan çalıştırmak gerekiyorsa repo checkout/extract kök dizininden çalıştırın

## Environment Variables

### Required
- `JWT_SECRET` - JWT signing secret (min 32 characters, must contain uppercase, lowercase, numbers, special chars)
- `POSTGRES_HOST` - PostgreSQL host
- `POSTGRES_PORT` - PostgreSQL port (default: 5432)
- `POSTGRES_ADMIN_USER` - PostgreSQL admin user
- `POSTGRES_ADMIN_PASSWORD` - PostgreSQL admin password
- `POSTGRES_DB` - PostgreSQL database name

### Optional
- `PORT` - Server port (default: 8080, min: 1, max: 65535)
- `NODE_ENV` - Environment (production/development)
- `LOG_LEVEL` - Log level (debug/info/warn/error, default: info in prod, debug in dev)
- `TRUST_PROXY` - Trust X-Forwarded-For header (true/false, default: false)
- `REQUEST_BODY_LIMIT_BYTES` - Max request body size (default: 1048576, min: 1024, max: 104857600)
- `REQUEST_TIMEOUT_MS` - Request timeout (default: 30000, min: 1000, max: 300000)
- `HEALTH_CHECK_TIMEOUT_MS` - Health check timeout (default: 5000, min: 1000, max: 30000)
- `ALLOWED_ORIGINS` - CORS allowed origins (comma-separated, e.g., `https://app.com,https://admin.com`)
- `ALLOWLIST_CACHE_TTL_MS` - IP allowlist cache TTL (default: 60000)
- `RATE_LIMIT_CLEANUP_INTERVAL_MS` - Rate limit cleanup interval (default: 300000)
- `LOGIN_RATE_LIMIT` - Max login attempts (default: 10)
- `LOGIN_RATE_WINDOW_SECONDS` - Login rate limit window (default: 300)

### Database Pool
- `DB_POOL_MAX` - Max pool size (default: 20)
- `DB_POOL_MIN` - Min pool size (default: 2)
- `DB_POOL_IDLE_TIMEOUT` - Idle timeout (default: 30000)
- `DB_POOL_CONNECTION_TIMEOUT` - Connection timeout (default: 10000)
- `DB_STATEMENT_TIMEOUT` - Statement timeout (default: 30000)
