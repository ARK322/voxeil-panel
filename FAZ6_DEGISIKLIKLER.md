# FAZ 6 — DNS MODÜLÜ (MODÜL 6)

## NE DEĞİŞTİ

### 1. DNS Zone Oluşturma
✅ **ZATEN DOĞRU:**
- `apps/controller/dns/bind9.js`:
  - DNS zone oluşturma ConfigMap kullanıyor (`bind9-zones` ConfigMap)
  - Zone dosyaları ConfigMap'te saklanıyor
  - Bind9 deployment restart ediliyor (zone reload için)

### 2. User Domain/Zone Create
✅ **ZATEN DOĞRU:**
- `apps/controller/sites/site.service.js` → `enableSiteDns()`:
  - Controller -> dns-zone servisine API çağrısı yapıyor
  - `ensureDnsZone()` fonksiyonu kullanılıyor
  - User namespace annotation'larına DNS bilgileri yazılıyor

### 3. Annotation Key'leri
✅ **GÜNCELLENDİ:**
- `enableSiteDns()`: `voxeil.io/site-${slug}-dnsEnabled`, `dnsDomain`, `dnsTarget` formatına güncellendi
- `disableSiteDns()`: Aynı format
- `purgeSiteDns()`: Aynı format
- `getSiteDnsStatus()`: Annotation okuma güncellendi

### 4. TSIG/Key Separation
⚠️ **MEVCUT DURUM:**
- `infra/k8s/services/dns-zone/tsig-secret.yaml`:
  - Tek bir TSIG secret var (`bind9-tsig`)
  - User bazlı TSIG/key separation yok (şimdilik kabul edilebilir)
  - İleride user bazlı TSIG eklenebilir

### 5. NetworkPolicy
✅ **ZATEN DOĞRU:**
- User namespace NetPol'unda dns-zone egress yok (beklenen)
- User ns dns-zone'a direkt erişmesin (gerek yok)
- Sadece controller/ops erişsin (controller platform namespace'den erişebilir)

## NASIL TEST EDİLİR

### Test 1: DNS Zone Oluşturma
```bash
# Site oluştur ve DNS enable et
curl -X POST http://localhost:8080/sites \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"domain":"test.example.com","cpu":1,"ramGi":1,"diskGi":5}'

curl -X POST http://localhost:8080/sites/<slug>/dns/enable \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"domain":"test.example.com","targetIp":"1.2.3.4"}'

# DNS zone kontrolü
kubectl get configmap bind9-zones -n dns-zone -o yaml
# Çıktı: named.conf.local ve db.test.example.com içermeli

# Zone dosyası kontrolü
kubectl get configmap bind9-zones -n dns-zone -o jsonpath='{.data.db\.test\.example\.com}'
# Çıktı: Zone file içeriği (SOA, NS, A records)

# Bind9 deployment restart kontrolü
kubectl get deployment bind9 -n dns-zone
kubectl describe deployment bind9 -n dns-zone | grep "Restarted At"
# Çıktı: Restart annotation'ı görünmeli
```

### Test 2: DNS Zone Served
```bash
# Bind9 pod logları
kubectl logs -n dns-zone deployment/bind9 --tail=50
# Çıktı: Zone loaded veya zone reloaded mesajları

# DNS query testi (bind9 pod içinden)
kubectl exec -n dns-zone deployment/bind9 -- dig @localhost test.example.com
# Çıktı: A record (1.2.3.4) dönmeli

# External DNS query (Traefik TCP route üzerinden)
dig @<traefik-ip> -p 53 test.example.com
# Çıktı: A record (1.2.3.4) dönmeli
```

### Test 3: DNS Zone Disable
```bash
# DNS disable
curl -X POST http://localhost:8080/sites/<slug>/dns/disable \
  -H "Authorization: Bearer $TOKEN"

# Zone silindi mi kontrol et
kubectl get configmap bind9-zones -n dns-zone -o jsonpath='{.data.named\.conf\.local}'
# Çıktı: test.example.com zone block'u olmamalı

kubectl get configmap bind9-zones -n dns-zone -o jsonpath='{.data.db\.test\.example\.com}'
# Çıktı: (boş) - Zone dosyası silinmiş olmalı
```

### Test 4: DNS Status
```bash
# DNS status
curl -X GET http://localhost:8080/sites/<slug>/dns/status \
  -H "Authorization: Bearer $TOKEN"

# Çıktı:
# {
#   "ok": true,
#   "slug": "<slug>",
#   "dnsEnabled": true,
#   "domain": "test.example.com",
#   "targetIp": "1.2.3.4"
# }
```

### Test 5: User Namespace - DNS Zone Erişimi Yok (Negatif Test)
```bash
# User namespace pod'dan dns-zone'a erişim testi
kubectl exec -n user-<userId> deployment/app-<slug> -- sh -c "nc -zv bind9.dns-zone.svc.cluster.local 53"
# Çıktı: Connection refused veya timeout (beklenen - DENY)

# DNS query testi (user namespace pod'dan)
kubectl exec -n user-<userId> deployment/app-<slug> -- nslookup test.example.com bind9.dns-zone.svc.cluster.local
# Çıktı: Connection refused veya timeout (beklenen - DENY)
```

### Test 6: Annotation Format
```bash
# User namespace annotation kontrolü
kubectl get namespace user-<userId> -o jsonpath='{.metadata.annotations}' | jq
# Çıktı:
# {
#   "voxeil.io/site-<slug>-dnsEnabled": "true",
#   "voxeil.io/site-<slug>-dnsDomain": "test.example.com",
#   "voxeil.io/site-<slug>-dnsTarget": "1.2.3.4"
# }
```

## BEKLENEN ÇIKTI

### ✅ PASS Kriterleri:
1. Zone create → ConfigMap'te zone oluşturuluyor
2. Bind9 reload → Zone served oluyor
3. DNS query → A record dönüyor
4. Zone disable → Zone siliniyor
5. User namespace → DNS zone'a erişim yok (beklenen)
6. Annotation format → `voxeil.io/site-${slug}-*` formatında

### ❌ FAIL Senaryoları:
1. Zone oluşturulmuyorsa
2. Bind9 reload olmuyorsa
3. DNS query başarısızsa
4. Zone silinmiyorsa
5. User namespace DNS zone'a erişebiliyorsa (DENY olmalı)
6. Annotation format yanlışsa

## NOTLAR

- DNS zone oluşturma: ConfigMap kullanıyor (bind9-zones)
- TSIG: Tek bir TSIG secret var (user bazlı separation yok - şimdilik kabul edilebilir)
- NetworkPolicy: User namespace'den dns-zone'a erişim yok (beklenen)
- Controller erişimi: Platform namespace'den controller erişebilir
- Zone reload: Bind9 deployment restart ile yapılıyor

## İLERİDE EKLENEBİLİR

- User bazlı TSIG/key separation
- Dynamic DNS update (DDNS) desteği
- Multiple DNS server desteği
- DNS zone validation
