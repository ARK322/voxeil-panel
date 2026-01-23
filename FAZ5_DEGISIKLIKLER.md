# FAZ 5 — BACKUP MİMARİSİ (MODÜL 5)

## NE DEĞİŞTİ

### 1. Backup Namespace
✅ **GÜNCELLENDİ:**
- `apps/controller/sites/site.service.js`:
  - **ÖNCE:** `BACKUP_NAMESPACE = "backup"`
  - **SONRA:** `BACKUP_NAMESPACE = "backup-system"`
  - Backup job'lar artık `backup-system` namespace'inde oluşturuluyor

### 2. Backup Job Environment Variables
✅ **GÜNCELLENDİ:**
- `apps/controller/sites/site.service.js`:
  - **ÖNCE:** `TENANT_NAMESPACE` env var
  - **SONRA:** `USER_NAMESPACE` env var
  - Backup runner artık user namespace'i doğru şekilde algılıyor

### 3. Restore Pod - User Home PVC
✅ **GÜNCELLENDİ:**
- `apps/controller/backup/helpers.js`:
  - **ÖNCE:** `site-data` PVC kullanıyordu
  - **SONRA:** `pvc-user-home` PVC kullanıyor
  - **ÖNCE:** Mount path: `/data`
  - **SONRA:** Mount path: `/home`, subPath: `sites/${slug}`
  - Restore pod artık user home PVC'yi doğru şekilde kullanıyor

### 4. Backup Credentials
✅ **ZATEN DOĞRU:**
- Backup credential'lar sadece backup-system namespace'de
- DB admin credentials env var olarak backup runner'a geçiliyor
- User namespace'de backup key yok (beklenen)

### 5. Backup Job Tasarımı
✅ **MEVCUT:**
- PVC backup (user home) → backup storage (`/backups/sites/<slug>/files/`)
- DB dump → backup storage (`/backups/sites/<slug>/db/`)
- Backup job'lar backup-system namespace'de çalışıyor
- Backup runner service account kullanılıyor

### 6. Restore Tasarımı
✅ **MEVCUT:**
- Restore sadece controller tarafından tetiklenebilir
- Restore pod user namespace'de oluşturuluyor (controller tarafından)
- User workload job yaratamaz (RBAC ile korumalı)

## NASIL TEST EDİLİR

### Test 1: Backup Namespace Kontrolü
```bash
# Backup namespace kontrolü
kubectl get namespace backup-system
# Çıktı: backup-system namespace olmalı

# Backup service account kontrolü
kubectl get serviceaccount -n backup-system
# Çıktı: backup-service olmalı

# Backup RBAC kontrolü
kubectl get role,rolebinding -n backup-system
# Çıktı: backup-service-role ve backup-service-binding olmalı
```

### Test 2: Backup Job Oluşturma
```bash
# Site oluştur ve backup enable et
curl -X POST http://localhost:8080/sites \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"domain":"test.example.com","cpu":1,"ramGi":1,"diskGi":5}'

curl -X POST http://localhost:8080/sites/<slug>/backup/enable \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"retentionDays":14,"schedule":"0 3 * * *"}'

# Backup CronJob kontrolü
kubectl get cronjob -n backup-system
# Çıktı: backup-<slug> olmalı

kubectl describe cronjob backup-<slug> -n backup-system
# Namespace: backup-system
# ServiceAccount: backup-runner
# Env: USER_NAMESPACE=user-<userId>
```

### Test 3: Backup Job Çalıştırma
```bash
# Manual backup trigger
curl -X POST http://localhost:8080/sites/<slug>/backup/run \
  -H "Authorization: Bearer $TOKEN"

# Backup Job kontrolü
kubectl get job -n backup-system -l controller=<slug>
# Çıktı: backup-run-<slug>-<timestamp> olmalı

# Backup Job pod kontrolü
kubectl get pods -n backup-system -l controller=<slug>
# Çıktı: backup-run-<slug>-<timestamp>-<pod-id> olmalı

# Backup Job logları
kubectl logs -n backup-system job/backup-run-<slug>-<timestamp>
# Çıktı: Backup işlemi logları
```

### Test 4: Backup Artifact Kontrolü
```bash
# Backup artifact'ları kontrol et (backup runner pod içinden)
kubectl exec -n backup-system <backup-pod> -- ls -la /backups/sites/<slug>/files/
# Çıktı: *.tar.gz veya *.tar.zst dosyaları olmalı

kubectl exec -n backup-system <backup-pod> -- ls -la /backups/sites/<slug>/db/
# Çıktı: *.sql.gz dosyaları olmalı (DB enabled ise)
```

### Test 5: Restore Pod - User Home PVC
```bash
# Restore trigger
curl -X POST http://localhost:8080/sites/<slug>/backup/restore \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"snapshotId":"<backup-id>","restoreFiles":true,"restoreDb":false}'

# Restore pod kontrolü
kubectl get pods -n user-<userId> -l app.kubernetes.io/name=restore-files
# Çıktı: restore-<slug>-<timestamp> olmalı

# Restore pod volume mount kontrolü
kubectl describe pod restore-<slug>-<timestamp> -n user-<userId>
# Volume Mounts:
#   - name: user-home
#     mountPath: /home
#     subPath: sites/<slug>
#   - name: backups
#     mountPath: /backups
#     readOnly: true

# Restore pod logları
kubectl logs restore-<slug>-<timestamp> -n user-<userId>
# Çıktı: Restore işlemi logları
```

### Test 6: User Namespace'de Backup Credential Yok (Negatif Test)
```bash
# User namespace'de backup credential kontrolü
kubectl get secrets -n user-<userId> | grep backup
# Çıktı: (boş) - Backup credential yok (beklenen)

# User namespace'de backup key kontrolü
kubectl get secrets -n user-<userId> -o json | jq '.items[] | select(.metadata.name | contains("backup"))'
# Çıktı: (boş) - Backup key yok (beklenen)
```

### Test 7: Backup Runner RBAC - User Namespace PVC Erişimi
```bash
# Backup runner service account'unun user namespace PVC'lerine erişimi
# (ClusterRole ve ClusterRoleBinding gerekli - infra/k8s/services/backup-system/rbac.yaml'da kontrol et)

# Test: Backup runner pod'unun user namespace PVC'yi mount edebilmesi
kubectl exec -n backup-system <backup-pod> -- ls -la /backups
# Çıktı: Backup dizini görünmeli

# Backup runner'ın user namespace'deki PVC'ye erişimi
# (Backup runner pod spec'inde volume mount kontrolü)
kubectl get cronjob backup-<slug> -n backup-system -o yaml | grep -A 10 volumes
# Çıktı: Backup volumes tanımlı olmalı
```

## BEKLENEN ÇIKTI

### ✅ PASS Kriterleri:
1. Backup namespace → `backup-system` kullanılıyor
2. Backup job → `backup-system` namespace'de oluşturuluyor
3. Backup credential → Sadece backup-system namespace'de
4. User namespace → Backup credential yok
5. Restore pod → User home PVC kullanıyor (subPath ile)
6. Backup artifact → `/backups/sites/<slug>/` altında oluşuyor
7. Restore → Controller tarafından tetiklenebilir

### ❌ FAIL Senaryoları:
1. Backup namespace yanlışsa ("backup" yerine "backup-system" olmalı)
2. Backup credential user namespace'de varsa
3. Restore pod yanlış PVC kullanıyorsa ("site-data" yerine "pvc-user-home")
4. Restore pod subPath kullanmıyorsa
5. Backup runner user namespace PVC'ye erişemiyorsa (RBAC eksik)

## NOTLAR

- Backup namespace: `backup-system` (güncellendi)
- Backup job'lar: `backup-system` namespace'de
- Backup credential: Sadece backup-system namespace'de (env var olarak)
- Restore pod: User namespace'de (controller tarafından oluşturuluyor)
- User home PVC: `pvc-user-home` (subPath: `sites/<slug>`)
- Backup runner RBAC: User namespace PVC'lere erişim için ClusterRole gerekli (infra'da kontrol et)

## EKSİK: Backup Runner RBAC

Backup runner service account'unun user namespace'deki PVC'lere erişebilmesi için ClusterRole ve ClusterRoleBinding eklenmeli:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: backup-runner-pvc-access
rules:
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: backup-runner-pvc-access
subjects:
  - kind: ServiceAccount
    name: backup-runner
    namespace: backup-system
roleRef:
  kind: ClusterRole
  name: backup-runner-pvc-access
  apiGroup: rbac.authorization.k8s.io
```

Bu RBAC'ı `infra/k8s/services/backup-system/rbac.yaml` dosyasına eklemek gerekebilir.
