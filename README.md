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

**Prod gate:** Production’a çıkmadan önce `doctor` komutunun `exit code 0` döndürmesi gerekir.

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

`doctor` komutu Production’a çıkmadan önce sistem durumunu kontrol eder:

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
