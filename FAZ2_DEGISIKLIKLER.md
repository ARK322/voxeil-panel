# FAZ 2 — USER HOME PVC STANDARDI (MODÜL 2)

## NE DEĞİŞTİ

### 1. User Bootstrap - PVC Oluşturma
✅ **ZATEN MEVCUT:**
- `apps/controller/users/user.bootstrap.js:123` → `ensureUserHomePvc(namespace)` çağrılıyor
- User namespace oluşturulunca otomatik olarak `pvc-user-home` PVC'si oluşturuluyor

### 2. PVC Yapılandırması
✅ **ZATEN MEVCUT:**
- `apps/controller/k8s/pvc.js`:
  - `USER_HOME_PVC_NAME = "pvc-user-home"`
  - `DEFAULT_USER_HOME_SIZE_GI = 10` (10Gi default)
  - `DEFAULT_STORAGE_CLASS = process.env.STORAGE_CLASS_NAME ?? "local-path"`
  - PVC labels: `voxeil.io/pvc-type: user-home`

### 3. Deployment PVC Mount
✅ **DÜZELTME YAPILDI:**
- `apps/controller/k8s/publish.js`:
  - **ÖNCE:** `mountPath: /home/sites/${spec.slug}` (subPath yok)
  - **SONRA:** 
    - `mountPath: "/home"`
    - `subPath: sites/${spec.slug}`
  - Bu sayede:
    - PVC `/home` olarak mount edilir
    - SubPath ile `sites/${slug}` altına gider
    - Sonuç: Container içinde `/home/sites/${slug}` path'i oluşur
    - Her site kendi subPath'inde dosyalarını saklar

### 4. Site Dosya Yönetimi
- Site silinince dosyalar otomatik silinmez (sadece K8s kaynakları silinir)
- Dosya yönetimi ayrı bir işlem (backup/restore modülünde)

## NASIL TEST EDİLİR

### Test 1: User Bootstrap - PVC Oluşturma
```bash
# User oluştur
curl -X POST http://localhost:8080/admin/users \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"testpass","email":"test@example.com","role":"user"}'

# PVC kontrolü
kubectl get pvc -n user-<userId>
# Çıktı: pvc-user-home olmalı

# PVC detayları
kubectl describe pvc pvc-user-home -n user-<userId>
# StorageClass: local-path (veya STORAGE_CLASS_NAME env var)
# Size: 10Gi (default)
# Labels: voxeil.io/pvc-type=user-home
```

### Test 2: Deployment PVC Mount
```bash
# Site oluştur ve deploy et
curl -X POST http://localhost:8080/sites \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"domain":"test.example.com","cpu":1,"ramGi":1,"diskGi":5}'

curl -X POST http://localhost:8080/sites/<slug>/deploy \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"image":"nginx:latest","containerPort":80}'

# Deployment volume mount kontrolü
kubectl describe deployment app-<slug> -n user-<userId>
# Volume Mounts:
#   - name: user-home
#     mountPath: /home
#     subPath: sites/<slug>

# Pod içinde test
kubectl exec -n user-<userId> deployment/app-<slug> -- ls -la /home
# Çıktı: sites/ dizini görünmeli

kubectl exec -n user-<userId> deployment/app-<slug> -- ls -la /home/sites
# Çıktı: <slug> dizini görünmeli

# Dosya oluştur ve test et
kubectl exec -n user-<userId> deployment/app-<slug> -- sh -c "echo 'test' > /home/sites/<slug>/test.txt"
kubectl exec -n user-<userId> deployment/app-<slug> -- cat /home/sites/<slug>/test.txt
# Çıktı: test
```

### Test 3: İki Site Aynı PVC Üzerinde Farklı SubPath
```bash
# İkinci site oluştur
curl -X POST http://localhost:8080/sites \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"domain":"test2.example.com","cpu":1,"ramGi":1,"diskGi":5}'

curl -X POST http://localhost:8080/sites/<slug2>/deploy \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"image":"nginx:latest","containerPort":80}'

# Her iki deployment aynı PVC'yi kullanmalı
kubectl get deployment -n user-<userId> -o jsonpath='{.items[*].spec.template.spec.volumes[*].persistentVolumeClaim.claimName}'
# Çıktı: pvc-user-home pvc-user-home

# Farklı subPath'ler
kubectl get deployment app-<slug1> -n user-<userId> -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[0].subPath}'
# Çıktı: sites/<slug1>

kubectl get deployment app-<slug2> -n user-<userId> -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[0].subPath}'
# Çıktı: sites/<slug2>

# Dosya izolasyonu testi
kubectl exec -n user-<userId> deployment/app-<slug1> -- sh -c "echo 'site1' > /home/sites/<slug1>/file1.txt"
kubectl exec -n user-<userId> deployment/app-<slug2> -- sh -c "echo 'site2' > /home/sites/<slug2>/file2.txt"

# Site1'den site2 dosyasını görmemeli
kubectl exec -n user-<userId> deployment/app-<slug1> -- ls /home/sites/<slug2>/file2.txt
# Çıktı: No such file or directory (beklenen)

# Site2'den site1 dosyasını görmemeli
kubectl exec -n user-<userId> deployment/app-<slug2> -- ls /home/sites/<slug1>/file1.txt
# Çıktı: No such file or directory (beklenen)
```

### Test 4: Redeploy - Data Persistence
```bash
# Dosya oluştur
kubectl exec -n user-<userId> deployment/app-<slug> -- sh -c "echo 'persistent-data' > /home/sites/<slug>/data.txt"

# Deployment'ı yeniden başlat (image değiştir)
curl -X POST http://localhost:8080/sites/<slug>/deploy \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"image":"nginx:alpine","containerPort":80}'

# Pod yeniden başladıktan sonra dosya hala orada olmalı
kubectl exec -n user-<userId> deployment/app-<slug> -- cat /home/sites/<slug>/data.txt
# Çıktı: persistent-data (beklenen)
```

## BEKLENEN ÇIKTI

### ✅ PASS Kriterleri:
1. User bootstrap → `pvc-user-home` PVC oluşturuluyor
2. Deployment → PVC mount ediliyor, mountPath: `/home`, subPath: `sites/<slug>`
3. İki site → Aynı PVC üzerinde farklı subPath kullanıyor
4. Dosya izolasyonu → Site'ler birbirinin dosyalarını görmüyor
5. Data persistence → Redeploy sonrası dosyalar duruyor

### ❌ FAIL Senaryoları:
1. PVC oluşturulmuyorsa
2. MountPath yanlışsa (`/home/sites/<slug>` yerine `/home` olmalı)
3. SubPath eksikse
4. İki site aynı subPath kullanıyorsa
5. Dosya izolasyonu yoksa
6. Redeploy sonrası dosyalar kayboluyorsa

## NOTLAR

- PVC default size: 10Gi (DEFAULT_USER_HOME_SIZE_GI)
- StorageClass: `STORAGE_CLASS_NAME` env var veya `local-path` default
- Site silinince dosyalar otomatik silinmez (sadece K8s kaynakları silinir)
- Dosya yönetimi backup/restore modülünde ayrı işlenir
