# FAZ 0 — KISA DOĞRULAMA RAPORU

## 0.1) Repo Ağacı ve Kritik Akışlar

### User Create -> User Bootstrap Akışı
✅ **DOĞRU:**
- `apps/controller/http/routes.js:88-138` → `createUser()` → `bootstrapUserNamespace(userId)`
- `apps/controller/users/user.bootstrap.js:80-136` → `user-${userId}` namespace oluşturuyor
- Namespace + ResourceQuota + LimitRange + NetworkPolicy + RoleBinding + PVC oluşturuluyor
- User namespace formatı: `user-${userId}` ✅

### Site Create/Update/Delete/Deploy/List/Restore Akışları

#### Site Create
✅ **DOĞRU:**
- `apps/controller/sites/site.service.js:287-375` → `createSite()`
- Satır 304: `const namespace = \`user-${userId}\`;` ✅
- Site metadata namespace annotations'da saklanıyor: `voxeil.io/site-${slug}-*`
- Deployment/Service/Ingress `*-${siteSlug}` formatında oluşturuluyor ✅

#### Site Update Limits
❌ **UYUMSUZ:**
- `apps/controller/sites/site.service.js:463-497` → `updateSiteLimits()`
- Satır 467: `const namespace = \`tenant-${slug}\`;` ❌
- `loadTenantTemplates()` kullanıyor ❌
- User namespace kullanmalı

#### Site Deploy
❌ **UYUMSUZ:**
- `apps/controller/sites/site.service.js:498-541` → `deploySite()`
- Satır 506: `const namespace = \`tenant-${normalized}\`;` ❌
- `readTenantNamespace()` kullanıyor ❌
- User namespace kullanmalı

#### Site Delete
❌ **UYUMSUZ:**
- `apps/controller/sites/site.service.js:542-552` → `deleteSite()`
- Satır 550: `await deleteTenantNamespace(normalized);` ❌
- User namespace'deki site kaynaklarını silmeli

#### Site List
❌ **UYUMSUZ:**
- `apps/controller/sites/site.service.js:376-462` → `listSites()`
- Satır 379: `const namespaces = await listTenantNamespaces();` ❌
- User namespace'lerden site'leri listeleme yapmalı

#### Site Restore
❌ **UYUMSUZ:**
- `apps/controller/backup/restore.service.js:117-144` → `restoreSiteFiles()`
- Satır 119: `const namespace = \`tenant-${normalized}\`;` ❌
- User namespace kullanmalı

### Publish/Deploy (Deployment/Service/Ingress/PVC Mount)

✅ **DOĞRU:**
- `apps/controller/k8s/publish.js` → Resource naming: `app-${slug}`, `web-${slug}` ✅
- Labels: `LABELS.managedBy`, `LABELS.siteSlug` mevcut ✅
- PVC mount: `pvc-user-home` → `/home/sites/${slug}` ✅
- SubPath kullanımı doğru ✅

⚠️ **EKSİK:**
- `voxeil.io/user-id` label eksik (sadece `voxeil.io/site-slug` var)
- `voxeil.io/site: "true"` label eksik

## 0.2) Kilit Mimariyle Uyumsuz Referanslar

### "tenant-" Namespace Referansları

#### `apps/controller/k8s/namespace.js`
- Satır 5: `export const TENANT_PREFIX = "tenant-";` ❌ (Kullanılmamalı, ama helper fonksiyonlar için gerekebilir)
- Satır 61-97: `allocateTenantNamespace()` ❌ (Kullanılmamalı)
- Satır 99-111: `deleteTenantNamespace()` ❌ (Kullanılmamalı, user namespace'deki site kaynaklarını silmeli)
- Satır 113-124: `listTenantNamespaces()` ❌ (Kullanılmamalı, user namespace'lerden site listeleme yapmalı)
- Satır 126-143: `readTenantNamespace()` ❌ (Kullanılmamalı, user namespace'den site okumalı)
- Satır 145-153: `slugFromNamespace()` ❌ (tenant- prefix kontrolü yapıyor)

#### `apps/controller/sites/site.service.js`
- Satır 7: `import { allocateTenantNamespace, deleteTenantNamespace, listTenantNamespaces, readTenantNamespace, slugFromNamespace }` ❌
- Satır 377: `loadTenantTemplates()` ❌ (user template kullanmalı)
- Satır 379: `listTenantNamespaces()` ❌
- Satır 384: `slugFromNamespace()` ❌
- Satır 467: `const namespace = \`tenant-${slug}\`;` ❌
- Satır 469: `loadTenantTemplates()` ❌
- Satır 506: `const namespace = \`tenant-${normalized}\`;` ❌
- Satır 510: `loadTenantTemplates()` ❌
- Satır 550: `deleteTenantNamespace()` ❌
- Satır 561-1583: Tüm site fonksiyonlarında `readTenantNamespace()` kullanılıyor ❌ (37+ referans)

#### `apps/controller/backup/restore.service.js`
- Satır 119: `const namespace = \`tenant-${normalized}\`;` ❌

### Sabit İsimli Resource Referansları

✅ **DOĞRU:**
- `publish.js` → `app-${slug}`, `web-${slug}` formatında ✅
- `apply.js` → Default name'ler sadece fallback, gerçek kullanım metadata'dan geliyor ✅

### Yanlış NetPol Template Kullanımı

✅ **DOĞRU:**
- `user.bootstrap.js:116` → `renderUserNetworkPolicy(templates.networkPolicyDenyAll, namespace)` ✅
- User template doğru kullanılıyor ✅

⚠️ **EKSİK:**
- User NetPol template'inde infra-db egress var ✅
- Ancak label selector'lar kontrol edilmeli (managed-by: controller veya voxeil.io/user=true)

## UYUMSUZLUK LİSTESİ ÖZET

### Kritik (FAZ 1'de düzeltilmeli)

1. **`site.service.js` - `updateSiteLimits()`**
   - Satır 467: `tenant-${slug}` → `user-${userId}` olmalı
   - Site metadata'dan userId çıkarılmalı veya parametre olarak alınmalı

2. **`site.service.js` - `deploySite()`**
   - Satır 506: `tenant-${normalized}` → user namespace olmalı
   - Site metadata'dan userId çıkarılmalı

3. **`site.service.js` - `deleteSite()`**
   - Satır 550: `deleteTenantNamespace()` → user namespace'deki site kaynaklarını silmeli
   - Label selector ile: `voxeil.io/site-slug=${slug}`

4. **`site.service.js` - `listSites()`**
   - Satır 379: `listTenantNamespaces()` → user namespace'lerden site listeleme
   - Her user namespace'deki annotations'dan site'leri çıkarmalı

5. **`site.service.js` - Tüm diğer fonksiyonlar (37+ referans)**
   - `readTenantNamespace()` → `readUserNamespaceSite()` veya benzeri
   - Site metadata'dan userId çıkarılmalı

6. **`restore.service.js` - `restoreSiteFiles()`**
   - Satır 119: `tenant-${normalized}` → user namespace olmalı

7. **Label Standardı Eksik**
   - `voxeil.io/site: "true"` label eklenmeli
   - `voxeil.io/user-id: "${userId}"` label eklenmeli
   - Tüm site kaynaklarına (deployment/service/ingress/secret/cm) eklenmeli

### Orta Öncelik (FAZ 1'de veya sonrasında)

8. **`namespace.js` - Helper fonksiyonlar**
   - `findUserNamespaceBySiteSlug()` mevcut ✅
   - `readUserNamespaceSite()` mevcut ✅
   - Ancak tüm site.service.js fonksiyonları bunları kullanmıyor

9. **Template Kullanımı**
   - `loadTenantTemplates()` → `loadUserTemplates()` olmalı (site limit update için)
   - Ancak site'ler user namespace'de olduğu için ayrı quota/limitrange gerekmez
   - Site seviyesinde limit uygulanacaksa deployment resources'da belirtilmeli

## SONRAKİ ADIMLAR

FAZ 1'de şunlar yapılacak:
1. `updateSiteLimits()` → user namespace kullanımı
2. `deploySite()` → user namespace kullanımı
3. `deleteSite()` → user namespace'deki kaynakları silme
4. `listSites()` → user namespace'lerden listeleme
5. Tüm site fonksiyonlarında `readTenantNamespace()` → `readUserNamespaceSite()` veya benzeri
6. Label standardı ekleme
7. `restore.service.js` düzeltme
