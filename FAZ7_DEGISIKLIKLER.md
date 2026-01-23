# FAZ 7 — MAIL MODÜLÜ (MODÜL 7)

## NE DEĞİŞTİ

### 1. User Domain Enable Mail
✅ **ZATEN DOĞRU:**
- `apps/controller/sites/site.service.js` → `enableSiteMail()`:
  - Controller -> mailcow API çağrısı yapıyor
  - `ensureMailcowDomain()` ve `setMailcowDomainActive()` kullanılıyor
  - User namespace annotation'larına mail bilgileri yazılıyor

### 2. Mailbox/Alias Yönetimi
✅ **ZATEN DOĞRU:**
- `createSiteMailbox()`, `deleteSiteMailbox()`, `listSiteMailboxes()`
- `createSiteAlias()`, `deleteSiteAlias()`, `listSiteAliases()`
- Tüm fonksiyonlar mailcow API kullanıyor
- User namespace'den site metadata okunuyor

### 3. Annotation Key'leri
✅ **GÜNCELLENDİ:**
- `enableSiteMail()`: `voxeil.io/site-${slug}-mailEnabled`, `mailProvider`, `mailDomain`, `mailStatus`, `mailLastError` formatına güncellendi
- `disableSiteMail()`: Aynı format
- `purgeSiteMail()`: Aynı format
- Tüm mail fonksiyonları: Annotation okuma güncellendi (`annotations.mailDomain` vs `annotations[SITE_ANNOTATIONS.mailDomain]`)

### 4. NetworkPolicy
✅ **ZATEN DOĞRU:**
- User namespace NetPol'unda mail-zone egress yok (beklenen)
- User ns mail-zone'a direkt erişmesin (gerek yok)
- Sadece controller/ops erişsin (controller platform namespace'den mailcow API'ye erişebilir)

### 5. Mailcow API Credentials
✅ **ZATEN DOĞRU:**
- Mailcow API credentials env var olarak controller'a geçiliyor
- `MAILCOW_API_URL`, `MAILCOW_API_KEY` env var'ları
- User namespace'de mail credential yok (beklenen)

## NASIL TEST EDİLİR

### Test 1: Mail Domain Enable
```bash
# Site oluştur ve mail enable et
curl -X POST http://localhost:8080/sites \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"domain":"test.example.com","cpu":1,"ramGi":1,"diskGi":5}'

curl -X POST http://localhost:8080/sites/<slug>/mail/enable \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"domain":"test.example.com"}'

# Mail domain kontrolü (mailcow API)
# Mailcow admin panel'den veya API'den kontrol et

# Annotation kontrolü
kubectl get namespace user-<userId> -o jsonpath='{.metadata.annotations}' | jq
# Çıktı:
# {
#   "voxeil.io/site-<slug>-mailEnabled": "true",
#   "voxeil.io/site-<slug>-mailProvider": "mailcow",
#   "voxeil.io/site-<slug>-mailDomain": "test.example.com",
#   "voxeil.io/site-<slug>-mailStatus": "ready",
#   "voxeil.io/site-<slug>-mailLastError": ""
# }
```

### Test 2: Mailbox Oluşturma
```bash
# Mailbox oluştur
curl -X POST http://localhost:8080/sites/<slug>/mail/mailbox \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"localPart":"test","password":"Test123!","quotaMb":100}'

# Mailbox listesi
curl -X GET http://localhost:8080/sites/<slug>/mail/mailbox \
  -H "Authorization: Bearer $TOKEN"

# Çıktı:
# {
#   "ok": true,
#   "slug": "<slug>",
#   "domain": "test.example.com",
#   "mailboxes": ["test@test.example.com"]
# }
```

### Test 3: Mailbox SMTP/IMAP Test
```bash
# SMTP test (mailcow üzerinden)
# Mailcow admin panel'den veya external mail client ile test et
# SMTP: mailcow.<domain>:587 (TLS)
# IMAP: mailcow.<domain>:993 (TLS)

# Mail gönderme testi
# Mail client ile test@test.example.com'dan mail gönder
```

### Test 4: Alias Oluşturma
```bash
# Alias oluştur
curl -X POST http://localhost:8080/sites/<slug>/mail/alias \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"sourceLocalPart":"info","destination":"test@test.example.com","active":true}'

# Alias listesi
curl -X GET http://localhost:8080/sites/<slug>/mail/alias \
  -H "Authorization: Bearer $TOKEN"

# Çıktı:
# {
#   "ok": true,
#   "slug": "<slug>",
#   "domain": "test.example.com",
#   "aliases": ["info@test.example.com"]
# }
```

### Test 5: Mail Disable
```bash
# Mail disable
curl -X POST http://localhost:8080/sites/<slug>/mail/disable \
  -H "Authorization: Bearer $TOKEN"

# Mail status
curl -X GET http://localhost:8080/sites/<slug>/mail/status \
  -H "Authorization: Bearer $TOKEN"

# Çıktı:
# {
#   "ok": true,
#   "slug": "<slug>",
#   "domain": "test.example.com",
#   "mailEnabled": false,
#   "activeInMailcow": false
# }
```

### Test 6: User Namespace - Mail Zone Erişimi Yok (Negatif Test)
```bash
# User namespace pod'dan mail-zone'a erişim testi
kubectl exec -n user-<userId> deployment/app-<slug> -- sh -c "nc -zv mailcow.mail-zone.svc.cluster.local 25"
# Çıktı: Connection refused veya timeout (beklenen - DENY)

kubectl exec -n user-<userId> deployment/app-<slug> -- sh -c "nc -zv mailcow.mail-zone.svc.cluster.local 587"
# Çıktı: Connection refused veya timeout (beklenen - DENY)

kubectl exec -n user-<userId> deployment/app-<slug> -- sh -c "nc -zv mailcow.mail-zone.svc.cluster.local 993"
# Çıktı: Connection refused veya timeout (beklenen - DENY)
```

### Test 7: Mail Credential Yok (Negatif Test)
```bash
# User namespace'de mail credential kontrolü
kubectl get secrets -n user-<userId> | grep mail
# Çıktı: (boş) - Mail credential yok (beklenen)

# Mailcow API key kontrolü
kubectl get secrets -n user-<userId> -o json | jq '.items[] | select(.metadata.name | contains("mail"))'
# Çıktı: (boş) - Mail credential yok (beklenen)
```

## BEKLENEN ÇIKTI

### ✅ PASS Kriterleri:
1. Mail enable → Mailcow'da domain oluşturuluyor
2. Mailbox create → Mailbox oluşturuluyor
3. SMTP/IMAP → Mail gönderme/alma çalışıyor
4. Alias create → Alias oluşturuluyor
5. Mail disable → Domain deaktif ediliyor
6. User namespace → Mail zone'a erişim yok (beklenen)
7. User namespace → Mail credential yok (beklenen)
8. Annotation format → `voxeil.io/site-${slug}-*` formatında

### ❌ FAIL Senaryoları:
1. Mail domain oluşturulmuyorsa
2. Mailbox oluşturulmuyorsa
3. SMTP/IMAP çalışmıyorsa
4. User namespace mail zone'a erişebiliyorsa (DENY olmalı)
5. User namespace'de mail credential varsa
6. Annotation format yanlışsa

## NOTLAR

- Mail provider: Mailcow (API kullanılıyor)
- Mail credentials: Sadece controller'da (env var)
- NetworkPolicy: User namespace'den mail-zone'a erişim yok (beklenen)
- Controller erişimi: Platform namespace'den controller mailcow API'ye erişebilir
- Mail domain: Site domain ile aynı olmalı

## İLERİDE EKLENEBİLİR

- Multiple mail provider desteği
- Mail quota yönetimi
- Mail forwarding rules
- Mail filtering rules
