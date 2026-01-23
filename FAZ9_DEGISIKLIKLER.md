# FAZ 9 — OBSERVABILITY + GUARDRAILS (MODÜL 9)

## NE DEĞİŞTİ

### 1. Audit Log
✅ **ZATEN DOĞRU:**
- `apps/controller/audit/audit.service.js`:
  - `logAudit()` fonksiyonu var
  - PostgreSQL'de `panel_audit_logs` tablosu oluşturuluyor
  - Action, actor, target, IP, success, error, meta bilgileri loglanıyor
  - Index'ler oluşturuluyor (action + created_at)

- `apps/controller/http/routes.js`:
  - `safeAudit()` helper fonksiyonu var
  - Login, user create, user delete, site create, site delete gibi kritik aksiyonlar loglanıyor
  - Audit log hataları sessizce yok sayılıyor (non-blocking)

### 2. Kyverno Policies
✅ **ZATEN DOĞRU:**
- `infra/k8s/services/kyverno/policies.yaml`:
  - `restrict-controller-sa` ClusterPolicy var
  - Controller-sa sadece `user-*` namespace'lerinde işlem yapabilir
  - Controller-sa `user-*` dışındaki namespace'lerde işlem yapamaz
  - Validation failure action: Enforce (zorunlu)

### 3. Resource Alerts
⚠️ **OPSİYONEL (EKLENMEDİ):**
- Resource alerts (Prometheus, Grafana, AlertManager) opsiyonel
- İleride eklenebilir

## NASIL TEST EDİLİR

### Test 1: Audit Log Schema
```bash
# PostgreSQL'e bağlan
kubectl exec -it -n infra-db statefulset/postgres -- psql -U postgres -d postgres

# Audit log tablosunu kontrol et
\dt panel_audit_logs

# Tablo yapısını kontrol et
\d panel_audit_logs

# Çıktı:
# Column      | Type                        | Nullable | Default
# ------------+-----------------------------+----------+---------
# id          | text                        | not null |
# action      | text                        | not null |
# actor_user_id | text                      |          |
# actor_username | text                     |          |
# target_type | text                        |          |
# target_id   | text                        |          |
# target      | text                        |          |
# ip          | text                        |          |
# success     | boolean                     |          |
# error       | text                        |          |
# meta        | jsonb                       |          |
# created_at  | timestamp with time zone    | not null | now()

# Index'leri kontrol et
\di panel_audit_logs*

# Çıktı:
# panel_audit_logs_action_idx
```

### Test 2: Audit Log Entries
```bash
# Get controller token
CONTROLLER_TOKEN=$(kubectl get secret platform-secrets -n platform -o jsonpath='{.data.ADMIN_API_KEY}' | base64 -d)

# User create (audit log)
curl -X POST http://localhost:8080/admin/users \
  -H "Authorization: Bearer ${CONTROLLER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"Test123!","email":"test@example.com","role":"user"}'

# Audit log kontrolü
kubectl exec -it -n infra-db statefulset/postgres -- psql -U postgres -d postgres -c \
  "SELECT action, actor_username, target_type, target_id, success, created_at FROM panel_audit_logs ORDER BY created_at DESC LIMIT 5;"

# Çıktı:
# action          | actor_username | target_type | target_id | success | created_at
# ----------------+----------------+-------------+-----------+---------+--------------------
# user.create     | admin          | user        | <id>      | t       | 2024-01-01 12:00:00
# auth.login      | admin          |             |           | t       | 2024-01-01 11:59:00
```

### Test 3: Kyverno Policy Enforcement
```bash
# Kyverno policy kontrolü
kubectl get clusterpolicy restrict-controller-sa

# Çıktı:
# NAME                  BACKGROUND   VALIDATION   READY
# restrict-controller-sa   false      Enforce     true

# Policy detayları
kubectl get clusterpolicy restrict-controller-sa -o yaml

# Test: Controller-sa user-* namespace'inde işlem yapabilir
kubectl auth can-i create deployment --as=system:serviceaccount:platform:controller-sa -n user-test123
# Çıktı: yes

# Test: Controller-sa user-* dışındaki namespace'de işlem yapamaz
kubectl auth can-i create deployment --as=system:serviceaccount:platform:controller-sa -n default
# Çıktı: no (Kyverno tarafından engellenecek)

# Test: Controller-sa platform namespace'inde namespace oluşturamaz (user-* dışında)
kubectl auth can-i create namespace --as=system:serviceaccount:platform:controller-sa
# Çıktı: no (Kyverno tarafından engellenecek - user-* dışında namespace oluşturamaz)
```

### Test 4: Audit Log Query
```bash
# Son 10 audit log entry
kubectl exec -it -n infra-db statefulset/postgres -- psql -U postgres -d postgres -c \
  "SELECT action, actor_username, target_type, success, error, created_at FROM panel_audit_logs ORDER BY created_at DESC LIMIT 10;"

# Başarısız login denemeleri
kubectl exec -it -n infra-db statefulset/postgres -- psql -U postgres -d postgres -c \
  "SELECT action, actor_username, ip, error, created_at FROM panel_audit_logs WHERE action = 'auth.login_failed' ORDER BY created_at DESC LIMIT 10;"

# User create/delete işlemleri
kubectl exec -it -n infra-db statefulset/postgres -- psql -U postgres -d postgres -c \
  "SELECT action, actor_username, target_type, target_id, success, created_at FROM panel_audit_logs WHERE action LIKE 'user.%' ORDER BY created_at DESC LIMIT 10;"

# Site create/delete işlemleri
kubectl exec -it -n infra-db statefulset/postgres -- psql -U postgres -d postgres -c \
  "SELECT action, actor_username, target_type, target_id, success, created_at FROM panel_audit_logs WHERE action LIKE 'site.%' ORDER BY created_at DESC LIMIT 10;"
```

### Test 5: Kyverno Policy Violation
```bash
# Test: Controller-sa ile user-* dışında namespace oluşturma denemesi
# (Bu test gerçek bir violation oluşturmaz, sadece policy'nin çalıştığını doğrular)

# Policy violation logları
kubectl get events -n kyverno --sort-by='.lastTimestamp' | grep -i "restrict-controller-sa" | tail -10

# Kyverno policy report
kubectl get policyreport -A | grep restrict-controller-sa
```

## BEKLENEN ÇIKTI

### ✅ PASS Kriterleri:
1. Audit log schema → Tablo ve index'ler oluşturuluyor
2. Audit log entries → Kritik aksiyonlar loglanıyor
3. Kyverno policy → Controller-sa sadece user-* namespace'lerinde işlem yapabilir
4. Policy enforcement → User-* dışındaki namespace'lerde işlem engelleniyor
5. Audit log query → Loglar sorgulanabiliyor

### ❌ FAIL Senaryoları:
1. Audit log tablosu oluşturulmuyorsa
2. Audit log entries yazılmıyorsa
3. Kyverno policy çalışmıyorsa
4. Controller-sa user-* dışında işlem yapabiliyorsa
5. Audit log query başarısızsa

## NOTLAR

- Audit log: PostgreSQL'de `panel_audit_logs` tablosunda saklanıyor
- Audit log actions: `auth.login`, `auth.login_failed`, `user.create`, `user.delete`, `site.create`, `site.delete`, vb.
- Kyverno policy: `restrict-controller-sa` ClusterPolicy (Enforce mode)
- Policy scope: Controller-sa sadece `user-*` namespace'lerinde işlem yapabilir
- Resource alerts: Opsiyonel (eklenmedi)

## İLERİDE EKLENEBİLİR

- Prometheus metrics export
- Grafana dashboards
- AlertManager rules (resource quota, pod failures, etc.)
- Audit log retention policy
- Audit log export (S3, etc.)
- Additional Kyverno policies (privilege container, hostPath, etc.)
