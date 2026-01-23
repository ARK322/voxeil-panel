# FAZ 8 — INSTALLER / BOOTSTRAP (MODÜL 8)

## NE DEĞİŞTİ

### 1. Installer Sırası
✅ **ZATEN DOĞRU:**
- `installer/installer.sh`:
  - k3s → traefik → cert-manager → kyverno → flux → platform → infra-db → dns-zone → mail-zone → backup-system
  - Sıralama doğru: Platform infra-db'ye bağımlı, infra-db önce hazır olmalı

### 2. Smoke Test Script
✅ **GÜNCELLENDİ:**
- `scripts/test-smoke.sh`:
  - **EKLENDİ:** Controller health check (Test 8)
  - **EKLENDİ:** User create test (Test 9):
    - User oluşturma
    - Namespace kontrolü (`user-<userId>`)
    - PVC kontrolü (`pvc-user-home`)
    - NetworkPolicy kontrolü (`deny-all`)
    - DB secret kontrolü (`db-conn`)
  - **EKLENDİ:** Site create test (Test 10):
    - 2 site oluşturma
    - Deployment kontrolü (`app-<slug>`)
    - Ingress kontrolü (`web-<slug>`)
    - Ingress host kontrolü
    - Her iki site aynı namespace'de kontrolü

### 3. Installer Sıralama Kontrolü
✅ **ZATEN DOĞRU:**
- Platform workloads infra-db hazır olduktan sonra uygulanıyor
- Backup-system backup images import edildikten sonra uygulanıyor
- Tüm servisler sırayla bekleniyor (wait conditions)

## NASIL TEST EDİLİR

### Test 1: Fresh Cluster Install
```bash
# Fresh k3s cluster'da kurulum
curl -fsSL https://raw.githubusercontent.com/ARK322/voxeil-panel/main/install.sh | bash

# Veya installer.sh direkt
bash installer/installer.sh

# Kurulum sırası kontrolü:
# 1. k3s install
# 2. Traefik config
# 3. cert-manager install + wait
# 4. Kyverno install + wait
# 5. Flux install + wait
# 6. Platform namespace + RBAC + PVC + secrets
# 7. infra-db install + wait (postgres ready)
# 8. Platform workloads (controller + panel)
# 9. dns-zone install + wait
# 10. mail-zone install + wait
# 11. backup-system install + wait
```

### Test 2: Smoke Test Script
```bash
# Smoke test çalıştır
bash scripts/test-smoke.sh

# Beklenen çıktı:
# === VOXEIL PANEL SMOKE TEST ===
# 
# 1. Checking kubectl access...
# ✓ kubectl can access cluster
# 
# 2. Checking required namespaces...
# ✓ Namespace platform exists
# ✓ Namespace infra-db exists
# ✓ Namespace backup-system exists
# ✓ Namespace dns-zone exists
# ✓ Namespace mail-zone exists
# ...
# 
# 8. Checking controller health...
# ✓ Controller health endpoint is OK
# 
# 9. Testing user create (namespace + PVC + NetPol + DB secret)...
# ✓ User created successfully
# ✓ User namespace user-<id> created
# ✓ User home PVC created
# ✓ User NetworkPolicy created
# ✓ DB secret created in user namespace
# 
# 10. Testing site create (2 sites, ingress check)...
# ✓ First site created successfully
# ✓ First site deployment created
# ✓ First site ingress created with correct host
# ✓ Second site created successfully
# ✓ Second site deployment created
# ✓ Second site ingress created with correct host
# ✓ Both sites in same user namespace
# 
# === TEST SUMMARY ===
# Total tests: <count>
# Passed: <count>
# Failed: 0
# 
# All smoke tests passed! ✓
```

### Test 3: Controller Health Check
```bash
# Controller health endpoint
kubectl port-forward -n platform svc/controller 8080:8080 &
CONTROLLER_PID=$!

sleep 2
curl http://localhost:8080/health
# Çıktı: {"ok":true,"checks":{"db":true,"k8s":true}}

kill $CONTROLLER_PID
```

### Test 4: User Create -> Bootstrap
```bash
# Get controller token
CONTROLLER_TOKEN=$(kubectl get secret platform-secrets -n platform -o jsonpath='{.data.ADMIN_API_KEY}' | base64 -d)

# Create user
curl -X POST http://localhost:8080/admin/users \
  -H "Authorization: Bearer ${CONTROLLER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"Test123!","email":"test@example.com","role":"user"}'

# Check namespace
kubectl get namespace user-<userId>
# Çıktı: user-<userId> olmalı

# Check PVC
kubectl get pvc pvc-user-home -n user-<userId>
# Çıktı: pvc-user-home olmalı

# Check NetPol
kubectl get networkpolicy deny-all -n user-<userId>
# Çıktı: deny-all olmalı

# Check DB secret
kubectl get secret db-conn -n user-<userId>
# Çıktı: db-conn olmalı
```

### Test 5: Site Create (2 Sites)
```bash
# Get user token (login)
USER_TOKEN=$(curl -X POST http://localhost:8080/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"Test123!"}' | jq -r '.token')

# Create first site
curl -X POST http://localhost:8080/sites \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"domain":"test1.example.com","cpu":1,"ramGi":1,"diskGi":5}'

# Create second site
curl -X POST http://localhost:8080/sites \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"domain":"test2.example.com","cpu":1,"ramGi":1,"diskGi":5}'

# Check deployments
kubectl get deployment -n user-<userId> -l voxeil.io/site=true
# Çıktı: app-<slug1> ve app-<slug2> olmalı

# Check ingresses
kubectl get ingress -n user-<userId> -l voxeil.io/site=true
# Çıktı: web-<slug1> ve web-<slug2> olmalı

# Check ingress hosts
kubectl get ingress web-<slug1> -n user-<userId> -o jsonpath='{.spec.rules[0].host}'
# Çıktı: test1.example.com

kubectl get ingress web-<slug2> -n user-<userId> -o jsonpath='{.spec.rules[0].host}'
# Çıktı: test2.example.com
```

## BEKLENEN ÇIKTI

### ✅ PASS Kriterleri:
1. Fresh cluster install → Tek komutla kurulum PASS
2. Controller health → Health endpoint OK
3. User create → Namespace + PVC + NetPol + DB secret oluşturuluyor
4. Site create (2 sites) → Her ikisi de aynı namespace'de, ingress'ler doğru host'a yönlendiriyor
5. Installer sırası → Doğru sırada (infra-db önce, platform sonra)

### ❌ FAIL Senaryoları:
1. Installer başarısız oluyorsa
2. Controller health check başarısızsa
3. User create namespace/PVC/NetPol/DB secret oluşturmuyorsa
4. Site create deployment/ingress oluşturmuyorsa
5. İki site farklı namespace'lerde oluşuyorsa
6. Ingress host'ları yanlışsa

## NOTLAR

- Installer sırası: k3s → traefik → cert-manager → kyverno → flux → platform → infra-db → dns/mail/backup
- Smoke test: Controller health + user create + site create testleri eklendi
- Test user: `smoketest-<timestamp>` formatında (unique)
- Test sites: `test1-<username>.example.com` ve `test2-<username>.example.com`
- CONTROLLER_TOKEN: platform-secrets'ten otomatik alınıyor veya env var olarak set edilebilir
