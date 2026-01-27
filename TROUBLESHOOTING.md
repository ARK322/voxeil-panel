# Voxeil Panel Troubleshooting Guide

## Panel'e Erişilemiyor

Kurulum tamamlandıktan sonra panele erişemiyorsanız, aşağıdaki adımları kontrol edin:

### Hızlı Kontrol

Sunucunuzda şu komutu çalıştırın:
```bash
bash scripts/check-panel-access.sh
```

Bu script şunları kontrol eder:
- DNS çözümlemesi
- Ingress durumu
- Sertifika durumu
- Traefik servisi
- Panel pod'ları
- Firewall ayarları
- Bağlantı testleri

### Manuel Kontroller

#### 1. DNS Kontrolü

`vhp.voxeil.com` domain'inin sunucunuzun IP adresine işaret ettiğinden emin olun:

```bash
# DNS'i kontrol et
dig vhp.voxeil.com +short
# veya
nslookup vhp.voxeil.com

# Sunucunuzun IP'sini öğrenin
curl ifconfig.me
```

**Önemli:** DNS kaydı doğru olmadan sertifika oluşturulamaz!

#### 2. Sertifika Durumu

Let's Encrypt sertifikasının oluşturulması 1-5 dakika sürebilir:

```bash
# Sertifika durumunu kontrol et
kubectl get certificate -n platform

# Sertifika detaylarını görüntüle
kubectl describe certificate -n platform

# Sertifika isteği durumunu kontrol et
kubectl get certificaterequest -n platform
```

Sertifika hazır değilse, şu hataları görebilirsiniz:
- `CertificateRequest` pending durumunda
- DNS doğrulama hatası

#### 3. Ingress Durumu

```bash
# Ingress durumunu kontrol et
kubectl get ingress panel -n platform
kubectl describe ingress panel -n platform
```

#### 4. Traefik Durumu

```bash
# Traefik pod'larını kontrol et
kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik

# Traefik servisini kontrol et
kubectl get svc -n kube-system -l app.kubernetes.io/name=traefik

# Traefik loglarını kontrol et
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik --tail=50
```

#### 5. Panel Pod'ları

```bash
# Panel pod'larını kontrol et
kubectl get pods -n platform -l app=panel

# Panel loglarını kontrol et
kubectl logs -n platform -l app=panel --tail=50
```

#### 6. Firewall (UFW)

Port 80 ve 443'ün açık olduğundan emin olun:

```bash
# UFW durumunu kontrol et
ufw status

# Gerekirse portları aç
ufw allow 80/tcp
ufw allow 443/tcp
```

### Yaygın Sorunlar ve Çözümleri

#### Sorun 0: Image Pull Hataları (EN YAYGIN)

**Belirtiler:**
- Kurulum sırasında "Failed to validate image" uyarıları
- Pod'lar ImagePullBackOff durumunda
- Panel pod'ları "Running" görünüyor ama erişilemiyor

**Hızlı Kontrol:**
```bash
# Tüm image pull hatalarını kontrol et
kubectl get pods -A | grep -E "(ImagePullBackOff|ErrImagePull)"

# Panel ve controller image'lerini kontrol et
kubectl get pods -n platform -l app=panel -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}'
kubectl get pods -n platform -l app=controller -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}'
```

**Çözüm:**
Image'ler henüz build edilmemiş veya registry'de yok. İki seçenek:

**Seçenek 1: Image'leri build edin ve push edin**
```bash
# Repository'yi clone edin (development için)
git clone https://github.com/ARK322/voxeil-panel.git
cd voxeil-panel

# Image'leri build edin ve GHCR'a push edin
./scripts/build-images.sh --push --tag latest
```

**Seçenek 2: Local image kullanın**
```bash
# Image'leri local olarak build edin
./scripts/build-images.sh --tag local

# Deployment'ları local image kullanacak şekilde güncelleyin
kubectl set image deployment/panel panel=ghcr.io/ark322/voxeil-panel:local -n platform
kubectl set image deployment/controller controller=ghcr.io/ark322/voxeil-controller:local -n platform

# k3s'e local image'leri import edin (gerekirse)
# k3s image import voxeil-panel:local
# k3s image import voxeil-controller:local
```

**Not:** Eğer image'ler build edilmemişse, pod'lar çalışmaz ve panel erişilemez.

#### Sorun 1: DNS Henüz Yapılandırılmamış

**Belirtiler:**
- `dig vhp.voxeil.com` sonuç vermiyor
- Sertifika oluşturulamıyor

**Çözüm:**
1. DNS A kaydını sunucunuzun IP'sine işaret edin
2. DNS propagasyonu için 5-10 dakika bekleyin
3. Sertifika otomatik olarak oluşturulacaktır

#### Sorun 2: Sertifika Henüz Oluşturulmamış

**Belirtiler:**
- `kubectl get certificate -n platform` pending gösteriyor
- HTTPS bağlantısı başarısız

**Çözüm:**
1. DNS'in doğru yapılandırıldığından emin olun
2. 5-10 dakika bekleyin
3. Cert-manager loglarını kontrol edin:
   ```bash
   kubectl logs -n cert-manager -l app=cert-manager --tail=50
   ```

#### Sorun 3: Traefik Çalışmıyor

**Belirtiler:**
- Traefik pod'ları CrashLoopBackOff durumunda
- Port 80/443 dinlemiyor

**Çözüm:**
```bash
# Traefik pod'larını yeniden başlat
kubectl delete pods -n kube-system -l app.kubernetes.io/name=traefik

# Logları kontrol et
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik
```

#### Sorun 4: Panel Pod'ları Çalışmıyor / Image Pull Hataları

**Belirtiler:**
- Panel pod'ları ImagePullBackOff, ErrImagePull veya CrashLoopBackOff durumunda
- Pod'lar "Running" görünüyor ama aslında çalışmıyor
- Kurulum sırasında image validation hatası

**Kontrol:**
```bash
# Pod durumunu detaylı kontrol et
kubectl get pods -n platform -l app=panel
kubectl describe pod -n platform -l app=panel

# Image pull hatalarını kontrol et
kubectl get pods -n platform -l app=panel -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].state.waiting.reason}{"\t"}{.status.containerStatuses[0].state.waiting.message}{"\n"}{end}' | grep -E "(ImagePullBackOff|ErrImagePull)"

# Kullanılan image'i kontrol et
kubectl get deployment panel -n platform -o jsonpath='{.spec.template.spec.containers[0].image}'
```

**Çözümler:**

1. **Image mevcut değilse - Build edin:**
   ```bash
   # Image'leri build et
   ./scripts/build-images.sh --tag local
   
   # Veya GHCR'a push edin
   ./scripts/build-images.sh --push --tag latest
   ```

2. **Private registry kullanıyorsanız - Authentication:**
   ```bash
   export GHCR_USERNAME=your-username
   export GHCR_TOKEN=your-token
   # Sonra deployment'ı yeniden oluşturun veya installer'ı tekrar çalıştırın
   ```

3. **Local image kullanmak için:**
   ```bash
   # Image'i local olarak build ettikten sonra
   kubectl set image deployment/panel panel=ghcr.io/ark322/voxeil-panel:local -n platform
   kubectl set image deployment/controller controller=ghcr.io/ark322/voxeil-controller:local -n platform
   ```

4. **Image'i manuel olarak kontrol edin:**
   ```bash
   # Image'in var olup olmadığını kontrol et
   docker pull ghcr.io/ark322/voxeil-panel:latest
   docker pull ghcr.io/ark322/voxeil-controller:latest
   ```

5. **Pod'ları yeniden başlatın:**
   ```bash
   # Deployment'ı restart edin
   kubectl rollout restart deployment/panel -n platform
   kubectl rollout restart deployment/controller -n platform
   ```

**Not:** Kurulum çıktısında image validation hatası görünse bile, k3s image'i çekmeyi deneyebilir. Eğer image yoksa pod'lar ImagePullBackOff durumunda kalır.

#### Sorun 5: Firewall Portları Kapalı

**Belirtiler:**
- Dışarıdan bağlantı kurulamıyor
- Port 80/443 dinlenmiyor

**Çözüm:**
```bash
# UFW portlarını aç
ufw allow 80/tcp
ufw allow 443/tcp
ufw reload

# Veya iptables kullanıyorsanız
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
```

### Test Komutları

#### HTTP Testi (Port 80)
```bash
curl -I http://vhp.voxeil.com
```

#### HTTPS Testi (Port 443)
```bash
curl -I -k https://vhp.voxeil.com
```

**Not:** `-k` flag'i self-signed sertifikalar için kullanılır. Let's Encrypt sertifikası hazır olduğunda gerekmez.

#### Yerel Test (Sunucu İçinden)
```bash
# Panel servisine doğrudan erişim
kubectl port-forward -n platform svc/panel 3000:3000
# Sonra tarayıcıda: http://localhost:3000
```

### Detaylı Log Kontrolü

Tüm servislerin loglarını kontrol etmek için:

```bash
# Cert-manager logları
kubectl logs -n cert-manager -l app=cert-manager --tail=100

# Traefik logları
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik --tail=100

# Panel logları
kubectl logs -n platform -l app=panel --tail=100

# Controller logları
kubectl logs -n platform -l app=controller --tail=100
```

### Sertifika Yeniden Oluşturma

Eğer sertifika sorunları devam ediyorsa:

```bash
# Mevcut sertifikayı sil
kubectl delete certificate -n platform
kubectl delete secret tls-panel -n platform

# Ingress'i yeniden oluştur (sertifika otomatik oluşturulacak)
kubectl delete ingress panel -n platform
kubectl apply -f <panel-ingress.yaml>
```

### Destek

Sorun devam ediyorsa:
1. `bash scripts/check-panel-access.sh` çıktısını kaydedin
2. Tüm log çıktılarını toplayın
3. GitHub Issues'da yeni bir issue açın
