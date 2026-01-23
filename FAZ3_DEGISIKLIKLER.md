# FAZ 3 — NETWORKPOLICY (PARANOYA) (MODÜL 3)

## NE DEĞİŞTİ

### 1. User Namespace NetworkPolicy
✅ **ZATEN DOĞRU:**
- `infra/k8s/templates/user/networkpolicy-deny-all.yaml`:
  - Default deny (ingress + egress) ✅
  - Allow ingress: Sadece Traefik (kube-system namespace, app.kubernetes.io/name: traefik) ✅
  - Allow egress:
    - kube-dns 53 TCP/UDP (kube-system namespace, k8s-app: kube-dns) ✅
    - infra-db 5432 (infra-db namespace, app: postgres) ✅
  - Mail/DNS/Backup egress: KAPALI (beklenen) ✅

### 2. User Namespace Labels
✅ **ZATEN DOĞRU:**
- `infra/k8s/templates/user/namespace.yaml`:
  - `managed-by: controller` ✅
  - `voxeil.io/user: "true"` ✅
  - `voxeil.io/user-id: <userId>` ✅

### 3. infra-db NetworkPolicy
✅ **GÜNCELLENDİ:**
- `infra/k8s/services/infra-db/networkpolicy.yaml`:
  - **ÖNCE:** Sadece `managed-by: controller` kontrolü
  - **SONRA:** 
    - `managed-by: controller` VEYA
    - `voxeil.io/user: "true"` kontrolü eklendi
  - Bu sayede user namespace'lerden (her iki label ile) 5432 portuna erişim sağlanıyor

## NASIL TEST EDİLİR

### Test 1: User Namespace NetPol - Default Deny
```bash
# User oluştur ve site deploy et
curl -X POST http://localhost:8080/admin/users \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"testpass","email":"test@example.com","role":"user"}'

curl -X POST http://localhost:8080/sites \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"domain":"test.example.com","cpu":1,"ramGi":1,"diskGi":5}'

curl -X POST http://localhost:8080/sites/<slug>/deploy \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"image":"nginx:latest","containerPort":80}'

# NetPol kontrolü
kubectl get networkpolicy -n user-<userId>
# Çıktı: deny-all olmalı

kubectl describe networkpolicy deny-all -n user-<userId>
# Policy Types: Ingress, Egress
# Ingress: Traefik (kube-system) - 80, 443
# Egress: kube-dns (kube-system) - 53 UDP/TCP, infra-db (infra-db) - 5432
```

### Test 2: DNS Egress - PASS
```bash
# Pod içinde DNS testi
kubectl exec -n user-<userId> deployment/app-<slug> -- nslookup kubernetes.default.svc.cluster.local
# Çıktı: DNS çözümleme başarılı olmalı

kubectl exec -n user-<userId> deployment/app-<slug> -- nslookup google.com
# Çıktı: DNS çözümleme başarılı olmalı
```

### Test 3: infra-db Egress - PASS
```bash
# Pod içinde PostgreSQL bağlantı testi
# (DB secret'ı varsa)
kubectl exec -n user-<userId> deployment/app-<slug> -- sh -c "nc -zv <db-host> 5432"
# Çıktı: Connection successful (beklenen)

# Veya psql ile test (DB credentials varsa)
kubectl exec -n user-<userId> deployment/app-<slug> -- psql -h <db-host> -p 5432 -U <db-user> -d <db-name> -c "SELECT 1"
# Çıktı: 1 (beklenen)
```

### Test 4: Mail/DNS/Backup Egress - DENY (Beklenen)
```bash
# Pod içinde mail-zone erişim testi (DENY beklenen)
kubectl exec -n user-<userId> deployment/app-<slug> -- sh -c "nc -zv mailcow.mail-zone.svc.cluster.local 25"
# Çıktı: Connection refused veya timeout (beklenen - DENY)

# Pod içinde dns-zone erişim testi (DENY beklenen)
kubectl exec -n user-<userId> deployment/app-<slug> -- sh -c "nc -zv bind9.dns-zone.svc.cluster.local 53"
# Çıktı: Connection refused veya timeout (beklenen - DENY)

# Pod içinde backup-system erişim testi (DENY beklenen)
kubectl exec -n user-<userId> deployment/app-<slug> -- sh -c "nc -zv backup-service.backup-system.svc.cluster.local 8080"
# Çıktı: Connection refused veya timeout (beklenen - DENY)
```

### Test 5: Traefik Ingress - PASS
```bash
# Ingress kontrolü
kubectl get ingress -n user-<userId>
# Çıktı: web-<slug> olmalı

# Ingress detayları
kubectl describe ingress web-<slug> -n user-<userId>
# Backend: Service web-<slug>:80

# Traefik'ten site'ye erişim testi (external IP veya port-forward)
curl -H "Host: test.example.com" http://<traefik-ip>/
# Çıktı: nginx default page (beklenen)
```

### Test 6: infra-db NetPol - User Namespace Erişimi
```bash
# infra-db NetPol kontrolü
kubectl get networkpolicy -n infra-db
# Çıktı: postgres-ingress olmalı

kubectl describe networkpolicy postgres-ingress -n infra-db
# Ingress from:
#   - namespaceSelector: managed-by=controller
#   - namespaceSelector: voxeil.io/user="true"
#   - namespaceSelector: voxeil.io/tenant="true" (legacy)
#   - namespaceSelector: kubernetes.io/metadata.name=platform (controller pod)
#   - namespaceSelector: kubernetes.io/metadata.name=backup

# User namespace label kontrolü
kubectl get namespace user-<userId> --show-labels
# Çıktı: managed-by=controller,voxeil.io/user=true,voxeil.io/user-id=<userId>

# User namespace'den DB erişimi (Test 3'te zaten test edildi)
```

## BEKLENEN ÇIKTI

### ✅ PASS Kriterleri:
1. User ns pod → nslookup PASS (DNS egress)
2. User ns pod → postgres:5432 PASS (infra-db egress)
3. User ns pod → mail-zone DENY (beklenen)
4. User ns pod → dns-zone DENY (beklenen)
5. User ns pod → backup-system DENY (beklenen)
6. Traefik → user ns pod ingress PASS
7. infra-db NetPol → user namespace'lerden erişim PASS

### ❌ FAIL Senaryoları:
1. DNS çözümleme başarısızsa
2. PostgreSQL bağlantısı başarısızsa
3. Mail/DNS/Backup erişimi başarılıysa (DENY olmalı)
4. Traefik'ten site'ye erişim başarısızsa
5. infra-db NetPol user namespace'lerden erişime izin vermiyorsa

## NOTLAR

- User namespace NetPol template'i zaten doğru yapılandırılmış
- infra-db NetPol'u güncellendi: `voxeil.io/user: "true"` label desteği eklendi
- Mail/DNS/Backup egress şimdilik KAPALI (güvenlik için)
- Traefik ingress sadece kube-system namespace'inden geliyor (doğru)
