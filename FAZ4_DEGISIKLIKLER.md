# FAZ 4 — DB TENANTING (A MODELİ) + SECRET DAĞITIMI (MODÜL 4)

## NE DEĞİŞTİ

### 1. User Bootstrap - DB ve Secret Oluşturma
✅ **EKLENDİ:**
- `apps/controller/users/user.bootstrap.js`:
  - User oluşturulunca otomatik olarak:
    - `db_<userId>` database oluşturuluyor
    - `u_<userId>` role/user oluşturuluyor
    - Public schema revoke yapılıyor (güvenlik)
    - User namespace'e `db-conn` secret'ı yazılıyor:
      - `host`, `port`, `database`, `username`, `password`, `url`
      - Label: `voxeil.io/secret-type: db-connection`

### 2. DB Naming Standardı
✅ **MEVCUT:**
- `apps/controller/postgres/admin.js`:
  - `DB_NAME_PREFIX` env var veya `db_` default
  - `DB_USER_PREFIX` env var veya `u_` default
  - Format: `db_<userId>`, `u_<userId>`

### 3. DB Security
✅ **MEVCUT:**
- `ensureDatabase()` fonksiyonu:
  - `REVOKE ALL ON DATABASE <db> FROM PUBLIC` ✅
  - `GRANT ALL PRIVILEGES ON DATABASE <db> TO <user>` ✅
  - Diğer database'lere CONNECT revoke ✅

### 4. User Delete - DB Cleanup
✅ **EKLENDİ:**
- `apps/controller/http/routes.js`:
  - User silinince:
    - DB bağlantıları terminate ediliyor
    - Database drop ediliyor
    - Role drop ediliyor
    - Namespace siliniyor (secret'lar otomatik silinir)

### 5. Site DB Kullanımı
✅ **MEVCUT:**
- Tüm site'ler aynı user DB'yi paylaşır (`db_<userId>`)
- Site bazlı schema eklenebilir (şimdilik yok)
- Her site kendi DB secret'ını kullanabilir (varsa) veya user-level `db-conn` secret'ını kullanabilir

## NASIL TEST EDİLİR

### Test 1: User Bootstrap - DB ve Secret Oluşturma
```bash
# User oluştur
curl -X POST http://localhost:8080/admin/users \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"testpass","email":"test@example.com","role":"user"}'

# DB kontrolü (PostgreSQL'e bağlan)
psql -h <db-host> -U <admin-user> -d postgres -c "SELECT datname FROM pg_database WHERE datname LIKE 'db_%';"
# Çıktı: db_<userId> olmalı

psql -h <db-host> -U <admin-user> -d postgres -c "SELECT rolname FROM pg_roles WHERE rolname LIKE 'u_%';"
# Çıktı: u_<userId> olmalı

# Secret kontrolü
kubectl get secret db-conn -n user-<userId>
# Çıktı: db-conn secret olmalı

kubectl get secret db-conn -n user-<userId> -o jsonpath='{.data}' | jq
# Çıktı: host, port, database, username, password, url (base64 encoded)

# Secret içeriği decode
kubectl get secret db-conn -n user-<userId> -o jsonpath='{.data.database}' | base64 -d
# Çıktı: db_<userId>

kubectl get secret db-conn -n user-<userId> -o jsonpath='{.data.username}' | base64 -d
# Çıktı: u_<userId>
```

### Test 2: DB Bağlantı Testi - User Namespace'den
```bash
# Pod içinde DB bağlantı testi
kubectl exec -n user-<userId> deployment/app-<slug> -- sh -c "echo \$DB_HOST \$DB_PORT \$DB_NAME \$DB_USER"
# Çıktı: DB env vars yoksa (secret envFrom kullanılmıyorsa)

# Secret'ı env olarak mount et (deployment'a ekle)
# Veya direkt psql ile test
kubectl exec -n user-<userId> deployment/app-<slug> -- sh -c "cat /var/run/secrets/kubernetes.io/serviceaccount/namespace"
# Çıktı: user-<userId>

# DB bağlantısı test et (secret'tan bilgileri al)
DB_HOST=$(kubectl get secret db-conn -n user-<userId> -o jsonpath='{.data.host}' | base64 -d)
DB_PORT=$(kubectl get secret db-conn -n user-<userId> -o jsonpath='{.data.port}' | base64 -d)
DB_NAME=$(kubectl get secret db-conn -n user-<userId> -o jsonpath='{.data.database}' | base64 -d)
DB_USER=$(kubectl get secret db-conn -n user-<userId> -o jsonpath='{.data.username}' | base64 -d)
DB_PASS=$(kubectl get secret db-conn -n user-<userId> -o jsonpath='{.data.password}' | base64 -d)

# Pod içinde test (psql varsa)
kubectl exec -n user-<userId> deployment/app-<slug> -- sh -c "PGPASSWORD=$DB_PASS psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c 'SELECT 1'"
# Çıktı: 1 (beklenen)
```

### Test 3: DB İzolasyonu - Negatif Test
```bash
# Başka bir user oluştur
curl -X POST http://localhost:8080/admin/users \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser2","password":"testpass2","email":"test2@example.com","role":"user"}'

# User2'nin DB bilgilerini al
DB_USER2=$(kubectl get secret db-conn -n user-<userId2> -o jsonpath='{.data.username}' | base64 -d)
DB_PASS2=$(kubectl get secret db-conn -n user-<userId2> -o jsonpath='{.data.password}' | base64 -d)
DB_NAME2=$(kubectl get secret db-conn -n user-<userId2> -o jsonpath='{.data.database}' | base64 -d)

# User1 namespace'den User2 DB'sine bağlanmaya çalış (BAŞARISIZ OLMALI)
kubectl exec -n user-<userId1> deployment/app-<slug1> -- sh -c "PGPASSWORD=$DB_PASS2 psql -h <db-host> -p 5432 -U $DB_USER2 -d $DB_NAME2 -c 'SELECT 1'"
# Çıktı: permission denied veya authentication failed (beklenen - DENY)
```

### Test 4: Public Schema Revoke - Güvenlik Testi
```bash
# User DB'sine bağlan
DB_HOST=$(kubectl get secret db-conn -n user-<userId> -o jsonpath='{.data.host}' | base64 -d)
DB_PORT=$(kubectl get secret db-conn -n user-<userId> -o jsonpath='{.data.port}' | base64 -d)
DB_NAME=$(kubectl get secret db-conn -n user-<userId> -o jsonpath='{.data.database}' | base64 -d)
DB_USER=$(kubectl get secret db-conn -n user-<userId> -o jsonpath='{.data.username}' | base64 -d)
DB_PASS=$(kubectl get secret db-conn -n user-<userId> -o jsonpath='{.data.password}' | base64 -d)

# Public schema'ya erişim testi
psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c "SELECT * FROM information_schema.tables WHERE table_schema = 'public';"
# Çıktı: Boş olmalı veya sadece user'ın kendi tabloları (beklenen)

# Public schema'da tablo oluşturma testi
psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c "CREATE TABLE test_table (id INT);"
# Çıktı: CREATE TABLE (beklenen - user kendi DB'sinde tablo oluşturabilir)
```

### Test 5: User Delete - DB Cleanup
```bash
# User sil
curl -X DELETE http://localhost:8080/admin/users/<userId> \
  -H "Authorization: Bearer $TOKEN"

# DB kontrolü (silinmiş olmalı)
psql -h <db-host> -U <admin-user> -d postgres -c "SELECT datname FROM pg_database WHERE datname = 'db_<userId>';"
# Çıktı: (0 rows) - DB silinmiş olmalı

psql -h <db-host> -U <admin-user> -d postgres -c "SELECT rolname FROM pg_roles WHERE rolname = 'u_<userId>';"
# Çıktı: (0 rows) - Role silinmiş olmalı

# Namespace kontrolü (silinmiş olmalı)
kubectl get namespace user-<userId>
# Çıktı: Error from server (NotFound) - Namespace silinmiş olmalı
```

## BEKLENEN ÇIKTI

### ✅ PASS Kriterleri:
1. User bootstrap → `db_<userId>` ve `u_<userId>` oluşturuluyor
2. User bootstrap → `db-conn` secret user namespace'de oluşturuluyor
3. User ns pod → DB'ye bağlanabiliyor (secret'tan bilgilerle)
4. DB izolasyonu → Başka user'ın DB'sine erişim yok
5. Public schema revoke → Doğru çalışıyor
6. User delete → DB, role, namespace temizleniyor

### ❌ FAIL Senaryoları:
1. DB oluşturulmuyorsa
2. Secret oluşturulmuyorsa
3. DB bağlantısı başarısızsa
4. DB izolasyonu yoksa (başka user'ın DB'sine erişim varsa)
5. User delete sonrası DB/role/namespace temizlenmiyorsa

## NOTLAR

- DB naming: `db_<userId>`, `u_<userId>` (prefix'ler env var ile değiştirilebilir)
- Secret name: `db-conn` (user namespace'de)
- Tüm site'ler aynı user DB'yi paylaşır (A modeli)
- Site bazlı schema eklenebilir (ileride)
- Public schema revoke yapılıyor (güvenlik)
