# FAZ 1 — SİTE LIFECYCLE'IN TAMAMI USER NAMESPACE'E (MODÜL 1.1)

## NE DEĞİŞTİ

### 1. Helper Fonksiyonlar Eklendi
- `apps/controller/k8s/namespace.js`:
  - `resolveUserNamespaceForSite(slug)` - Site slug'dan user namespace bulur
  - `extractUserIdFromNamespace(namespace)` - User namespace'den userId çıkarır
  - `readSiteMetadata(slug)` - Site metadata'sını okur (readTenantNamespace yerine)

### 2. Label Standardı Eklendi
- `apps/controller/k8s/client.js`:
  - `LABELS.siteSlug` eklendi: `"voxeil.io/site-slug"`
  
- `apps/controller/k8s/publish.js`:
  - Tüm resource'lara (Deployment/Service/Ingress) label'lar eklendi:
    - `voxeil.io/site: "true"`
    - `voxeil.io/user-id: "${userId}"` (varsa)
    - `voxeil.io/site-slug: "${slug}"`

### 3. Site Lifecycle Fonksiyonları Güncellendi

#### `listSites()`
- ❌ `listTenantNamespaces()` → ✅ User namespace'lerden site listeleme
- Tüm user namespace'leri tarayıp `voxeil.io/site-*-domain` annotation'larından site'leri buluyor

#### `updateSiteLimits()`
- ❌ `tenant-${slug}` → ✅ User namespace kullanımı
- ❌ Quota/LimitRange güncelleme → ✅ Deployment resources güncelleme
- Site seviyesinde limit uygulanacaksa deployment resources'da belirtiliyor
- User namespace quota/limitrange sabit kalıyor

#### `deploySite()`
- ❌ `tenant-${normalized}` → ✅ User namespace kullanımı
- ❌ `readTenantNamespace()` → ✅ `readSiteMetadata()`
- Site metadata'sından limit'leri alıyor

#### `deleteSite()`
- ❌ `deleteTenantNamespace()` → ✅ User namespace'deki site kaynaklarını silme
- Label selector ile tüm site kaynakları siliniyor:
  - Deployment: `app-${slug}`
  - Service: `web-${slug}`
  - Ingress: `web-${slug}`
  - Secrets/ConfigMaps (label ile)
  - Namespace annotation'ları temizleniyor

#### `restoreSiteFiles()`
- ❌ `tenant-${normalized}` → ✅ User namespace kullanımı

### 4. Annotation Helper Fonksiyonları
- `apps/controller/k8s/annotations.js`:
  - `getSiteAnnotationKey(slug, prop)` - Site annotation key oluşturur
  - `getSiteAnnotation(annotations, slug, prop)` - Site annotation okur (eski ve yeni format desteği)

### 5. Kalan Fonksiyonlar
- Tüm diğer site fonksiyonlarında `readTenantNamespace()` → `readSiteMetadata()` değiştirildi
- Annotation erişimleri güncellenmeye devam ediyor (pattern: `annotations.propName`)

## NASIL TEST EDİLİR

### Test 1: Site Create (Zaten User Namespace'de)
```bash
# Controller'a bağlan
kubectl port-forward -n platform svc/controller 8080:8080

# User oluştur (namespace bootstrap otomatik)
curl -X POST http://localhost:8080/admin/users \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"testpass","email":"test@example.com","role":"user"}'

# Site oluştur
curl -X POST http://localhost:8080/sites \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"domain":"test1.example.com","cpu":1,"ramGi":1,"diskGi":5}'

# Namespace kontrolü
kubectl get namespace user-<userId>
kubectl get deployment -n user-<userId> -l voxeil.io/site-slug=<slug>
kubectl get service -n user-<userId> -l voxeil.io/site-slug=<slug>
kubectl get ingress -n user-<userId> -l voxeil.io/site-slug=<slug>
```

### Test 2: İki Site Aynı User'da (Kaynak Çakışması Yok)
```bash
# İkinci site oluştur
curl -X POST http://localhost:8080/sites \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"domain":"test2.example.com","cpu":1,"ramGi":1,"diskGi":5}'

# Her iki site aynı namespace'de olmalı
kubectl get deployment -n user-<userId>
# Çıktı: app-<slug1> ve app-<slug2> olmalı

# Ingress host'ları kontrol et
kubectl describe ingress -n user-<userId>
# Her ingress doğru service'e yönlendirmeli
```

### Test 3: Site Delete (Sadece O Site Kaynakları Silinmeli)
```bash
# Site sil
curl -X DELETE http://localhost:8080/sites/<slug1> \
  -H "Authorization: Bearer $TOKEN"

# Kontrol: Sadece slug1 kaynakları silinmeli, slug2 durmalı
kubectl get deployment -n user-<userId>
# Çıktı: Sadece app-<slug2> olmalı

kubectl get service -n user-<userId>
# Çıktı: Sadece web-<slug2> olmalı
```

### Test 4: Site List (İki Siteyi Listeleme)
```bash
# Site listesi
curl -X GET http://localhost:8080/sites \
  -H "Authorization: Bearer $TOKEN"

# Çıktı: Her iki site de listelenmeli
# Her site'nin namespace'i user-<userId> olmalı
```

### Test 5: Site Update Limits
```bash
# Site limit güncelle
curl -X PATCH http://localhost:8080/sites/<slug> \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"cpu":2,"ramGi":2}'

# Deployment resources kontrolü
kubectl describe deployment app-<slug> -n user-<userId>
# CPU: 2, Memory: 2Gi olmalı
```

### Test 6: Site Deploy
```bash
# Site deploy
curl -X POST http://localhost:8080/sites/<slug>/deploy \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"image":"nginx:latest","containerPort":80}'

# Deployment kontrolü
kubectl get deployment app-<slug> -n user-<userId>
kubectl get service web-<slug> -n user-<userId>
```

## BEKLENEN ÇIKTI

### ✅ PASS Kriterleri:
1. Site create → User namespace'de oluşuyor
2. İki site aynı user'da → Kaynak çakışması yok, her ikisi de aynı namespace'de
3. Ingress host → Doğru service'e yönlendiriyor
4. Site delete → Sadece o site kaynakları siliniyor
5. Site list → Tüm site'ler listeleniyor
6. Label'lar → Tüm resource'larda `voxeil.io/site: "true"`, `voxeil.io/site-slug`, `voxeil.io/user-id` var

### ❌ FAIL Senaryoları:
1. Site create → `tenant-*` namespace oluşuyorsa
2. İki site → Kaynak çakışması varsa (aynı isimli deployment/service)
3. Ingress → Yanlış service'e yönlendiriyorsa
4. Site delete → Diğer site kaynakları da siliniyorsa
5. Label'lar → Eksik veya yanlış label'lar varsa

## NOTLAR

- Kalan site fonksiyonları (enableSiteMail, enableSiteDb, vs.) için aynı pattern uygulanmalı
- Annotation erişimleri `annotations.propName` formatına güncellenmeye devam ediyor
- `SITE_ANNOTATIONS` kullanımları yavaşça `getSiteAnnotationKey()` ile değiştirilebilir
