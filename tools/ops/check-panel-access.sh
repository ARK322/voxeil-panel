#!/usr/bin/env bash
set -euo pipefail

# Diagnostic script to check why panel is not accessible
# Usage: bash scripts/check-panel-access.sh

echo "=== Voxeil Panel Access Diagnostic ==="
echo ""

# Check if kubectl is available
if ! command -v kubectl >/dev/null 2>&1; then
  echo "❌ kubectl not found. Please install k3s or configure kubectl."
  exit 1
fi

# Get panel domain from ingress
PANEL_DOMAIN=""
PANEL_DOMAIN=$(kubectl get ingress panel -n platform -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")
if [ -z "${PANEL_DOMAIN}" ]; then
  echo "❌ Panel ingress not found. Installation may have failed."
  exit 1
fi

echo "Panel Domain: ${PANEL_DOMAIN}"
echo ""

# 1. Check DNS resolution
echo "=== 1. DNS Resolution Check ==="
if command -v dig >/dev/null 2>&1; then
  DNS_IP=""
  DNS_IP=$(dig +short "${PANEL_DOMAIN}" | head -n1)
  if [ -z "${DNS_IP}" ]; then
    echo "❌ DNS not resolving: ${PANEL_DOMAIN}"
    echo "   → Point DNS A record for ${PANEL_DOMAIN} to this server's IP"
  else
    echo "✓ DNS resolves to: ${DNS_IP}"
    # Get server's public IP (try multiple methods)
    SERVER_IP=""
    if command -v curl >/dev/null 2>&1; then
      SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "")
    fi
    if [ -n "${SERVER_IP}" ] && [ "${DNS_IP}" != "${SERVER_IP}" ]; then
      echo "⚠️  Warning: DNS IP (${DNS_IP}) doesn't match server IP (${SERVER_IP})"
      echo "   → Update DNS A record to point to ${SERVER_IP}"
    elif [ -n "${SERVER_IP}" ]; then
      echo "✓ DNS points to correct server IP"
    fi
  fi
elif command -v nslookup >/dev/null 2>&1; then
  if nslookup "${PANEL_DOMAIN}" >/dev/null 2>&1; then
    echo "✓ DNS resolves"
  else
    echo "❌ DNS not resolving: ${PANEL_DOMAIN}"
    echo "   → Point DNS A record for ${PANEL_DOMAIN} to this server's IP"
  fi
else
  echo "⚠️  Cannot check DNS (dig/nslookup not available)"
  echo "   → Manually verify: DNS A record for ${PANEL_DOMAIN} points to this server"
fi
echo ""

# 2. Check ingress status
echo "=== 2. Ingress Status ==="
INGRESS_STATUS=""
INGRESS_STATUS=$(kubectl get ingress panel -n platform -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
if [ -n "${INGRESS_STATUS}" ]; then
  echo "✓ Ingress has load balancer: ${INGRESS_STATUS}"
else
  echo "ℹ️  Ingress status (normal for k3s/Traefik):"
  kubectl get ingress panel -n platform
fi
echo ""

# 3. Check certificate status
echo "=== 3. Certificate Status ==="
CERT_NAME=""
CERT_NAME=$(kubectl get ingress panel -n platform -o jsonpath='{.spec.tls[0].secretName}' 2>/dev/null || echo "")
if [ -n "${CERT_NAME}" ]; then
  echo "Certificate secret: ${CERT_NAME}"
  
  # Check if certificate secret exists
  if kubectl get secret "${CERT_NAME}" -n platform >/dev/null 2>&1; then
    CERT_READY=""
    CERT_READY=$(kubectl get secret "${CERT_NAME}" -n platform -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || echo "")
    if [ -n "${CERT_READY}" ]; then
      echo "✓ Certificate secret exists"
      echo "  Subject: ${CERT_READY}"
    else
      echo "⚠️  Certificate secret exists but may be invalid"
    fi
  else
    echo "❌ Certificate secret not found: ${CERT_NAME}"
  fi
  
  # Check cert-manager Certificate resource
  CERT_RESOURCE=$(kubectl get certificate -n platform -o jsonpath='{.items[?(@.spec.secretName=="'${CERT_NAME}'")].metadata.name}' 2>/dev/null || echo "")
  if [ -n "${CERT_RESOURCE}" ]; then
    CERT_READY_STATUS=$(kubectl get certificate "${CERT_RESOURCE}" -n platform -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [ "${CERT_READY_STATUS}" = "True" ]; then
      echo "✓ Certificate is Ready"
    else
      echo "⚠️  Certificate not ready yet"
      echo "   Status:"
      kubectl get certificate "${CERT_RESOURCE}" -n platform -o yaml | grep -A 5 "status:" || true
      
      # Check CertificateRequest for errors
      CERT_REQ=$(kubectl get certificaterequest -n platform -o jsonpath='{.items[?(@.spec.certificateName=="'${CERT_RESOURCE}'")].metadata.name}' 2>/dev/null | head -n1 || echo "")
      if [ -n "${CERT_REQ}" ]; then
        echo "   CertificateRequest status:"
        kubectl get certificaterequest "${CERT_REQ}" -n platform -o yaml | grep -A 10 "status:" || true
      fi
    fi
  else
    echo "⚠️  No Certificate resource found (cert-manager may not have created it yet)"
  fi
else
  echo "⚠️  No TLS configuration found in ingress"
fi
echo ""

# 4. Check Traefik service
echo "=== 4. Traefik Service Status ==="
TRAEFIK_SVC=""
TRAEFIK_SVC=$(kubectl get svc -n kube-system -l app.kubernetes.io/name=traefik -o name 2>/dev/null | head -n1 || echo "")
if [ -z "${TRAEFIK_SVC}" ]; then
  echo "❌ Traefik service not found"
else
  echo "✓ Traefik service: ${TRAEFIK_SVC}"
  kubectl get "${TRAEFIK_SVC}" -n kube-system
  echo ""
  echo "Ports:"
  kubectl get "${TRAEFIK_SVC}" -n kube-system -o jsonpath='{.spec.ports[*].port}' | tr ' ' '\n' | while read -r port; do
    echo "  - ${port}"
  done
fi
echo ""

# 5. Check panel pods and image status
echo "=== 5. Panel Pods & Image Status ==="
PANEL_PODS=""
PANEL_PODS=$(kubectl get pods -n platform -l app=panel --no-headers 2>/dev/null | wc -l || echo "0")
if [ "${PANEL_PODS}" -eq "0" ]; then
  echo "❌ No panel pods found"
else
  echo "Panel pods:"
  kubectl get pods -n platform -l app=panel
  echo ""
  echo "Pod status details:"
  kubectl get pods -n platform -l app=panel -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.status.containerStatuses[0].ready}{"\n"}{end}'
  echo ""
  
  # Check for image pull errors
  echo "Checking for image pull errors..."
  IMAGE_PULL_ERRORS=""
  IMAGE_PULL_ERRORS=$(kubectl get pods -n platform -l app=panel \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].state.waiting.reason}{"\t"}{.status.containerStatuses[0].state.waiting.message}{"\n"}{end}' 2>/dev/null | \
    grep -E "(ImagePullBackOff|ErrImagePull|ImagePullError)" || true)
  
  if [ -n "${IMAGE_PULL_ERRORS}" ]; then
    echo "❌ IMAGE PULL ERRORS DETECTED:"
    echo "${IMAGE_PULL_ERRORS}" | while IFS=$'\t' read -r pod_name error_reason error_message; do
      echo "  Pod: ${pod_name}"
      echo "  Reason: ${error_reason}"
      echo "  Message: ${error_message}"
      echo ""
    done
    
    # Get image name from deployment
    PANEL_IMAGE=""
    PANEL_IMAGE=$(kubectl get deployment panel -n platform -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
    if [ -n "${PANEL_IMAGE}" ]; then
      echo "  Expected image: ${PANEL_IMAGE}"
      echo ""
      echo "  Possible solutions:"
      echo "  1. Build image locally: ./scripts/build-images.sh --tag local"
      echo "  2. Push image to registry: ./scripts/build-images.sh --push --tag latest"
      echo "  3. Check if image exists: crictl pull ${PANEL_IMAGE}  (or verify via kubectl get pods -n platform)"
      echo "  4. Use local image: kubectl set image deployment/panel panel=${PANEL_IMAGE/local} -n platform"
    fi
  else
    echo "✓ No image pull errors detected"
    
    # Check if pods are actually running (not just in Running state but ready)
    NOT_READY_PODS=$(kubectl get pods -n platform -l app=panel \
      -o jsonpath='{range .items[?(@.status.containerStatuses[0].ready==false)]}{.metadata.name}{"\t"}{.status.containerStatuses[0].state.waiting.reason}{"\t"}{.status.containerStatuses[0].state.waiting.message}{"\n"}{end}' 2>/dev/null || true)
    
    if [ -n "${NOT_READY_PODS}" ]; then
      echo "⚠️  Some pods are not ready:"
      echo "${NOT_READY_PODS}" | while IFS=$'\t' read -r pod_name reason message; do
        echo "  Pod: ${pod_name}"
        [ -n "${reason}" ] && echo "  Reason: ${reason}"
        [ -n "${message}" ] && echo "  Message: ${message}"
        echo ""
      done
    fi
  fi
  
  # Check actual image being used
  echo "Images in use:"
  kubectl get pods -n platform -l app=panel -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
fi
echo ""

# 6. Check controller pods and images (panel depends on controller)
echo "=== 6. Controller Pods & Image Status ==="
CONTROLLER_PODS=""
CONTROLLER_PODS=$(kubectl get pods -n platform -l app=controller --no-headers 2>/dev/null | wc -l || echo "0")
if [ "${CONTROLLER_PODS}" -eq "0" ]; then
  echo "⚠️  No controller pods found (panel depends on controller)"
else
  echo "Controller pods:"
  kubectl get pods -n platform -l app=controller
  echo ""
  
  # Check for image pull errors in controller
  CONTROLLER_IMAGE_ERRORS=""
  CONTROLLER_IMAGE_ERRORS=$(kubectl get pods -n platform -l app=controller \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].state.waiting.reason}{"\t"}{.status.containerStatuses[0].state.waiting.message}{"\n"}{end}' 2>/dev/null | \
    grep -E "(ImagePullBackOff|ErrImagePull|ImagePullError)" || true)
  
  if [ -n "${CONTROLLER_IMAGE_ERRORS}" ]; then
    echo "❌ CONTROLLER IMAGE PULL ERRORS:"
    echo "${CONTROLLER_IMAGE_ERRORS}" | while IFS=$'\t' read -r pod_name error_reason error_message; do
      echo "  Pod: ${pod_name}"
      echo "  Reason: ${error_reason}"
      echo "  Message: ${error_message}"
    done
    
    CONTROLLER_IMAGE=""
    CONTROLLER_IMAGE=$(kubectl get deployment controller -n platform -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
    if [ -n "${CONTROLLER_IMAGE}" ]; then
      echo "  Expected image: ${CONTROLLER_IMAGE}"
    fi
  else
    echo "✓ Controller: No image pull errors"
  fi
fi
echo ""

# 7. Check panel service
echo "=== 7. Panel Service Status ==="
if kubectl get svc panel -n platform >/dev/null 2>&1; then
  echo "✓ Panel service exists:"
  kubectl get svc panel -n platform
  echo ""
  # Check endpoints
  ENDPOINTS=""
  ENDPOINTS=$(kubectl get endpoints panel -n platform -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null || echo "")
  if [ -n "${ENDPOINTS}" ]; then
    echo "✓ Service has endpoints: ${ENDPOINTS}"
  else
    echo "❌ Service has no endpoints (pods may not be ready)"
  fi
else
  echo "❌ Panel service not found"
fi
echo ""

# 8. Check firewall (UFW)
echo "=== 8. Firewall Status ==="
if command -v ufw >/dev/null 2>&1; then
  UFW_STATUS=""
  UFW_STATUS=$(ufw status | head -n1 || echo "")
  echo "${UFW_STATUS}"
  if echo "${UFW_STATUS}" | grep -q "active"; then
    echo "Checking port 80:"
    ufw status | grep "80" || echo "  Port 80 not explicitly allowed"
    echo "Checking port 443:"
    ufw status | grep "443" || echo "  Port 443 not explicitly allowed"
  fi
else
  echo "ℹ️  UFW not installed (or using different firewall)"
fi
echo ""

# 9. Test connectivity
echo "=== 9. Connectivity Test ==="
if command -v curl >/dev/null 2>&1; then
  echo "Testing HTTP (port 80):"
  HTTP_CODE=""
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://${PANEL_DOMAIN}" 2>/dev/null || echo "000")
  if [ "${HTTP_CODE}" = "000" ]; then
    echo "  ❌ Cannot connect (timeout or DNS issue)"
  elif [ "${HTTP_CODE}" = "301" ] || [ "${HTTP_CODE}" = "302" ] || [ "${HTTP_CODE}" = "307" ] || [ "${HTTP_CODE}" = "308" ]; then
    echo "  ✓ HTTP redirects to HTTPS (${HTTP_CODE})"
  elif [ "${HTTP_CODE}" = "200" ]; then
    echo "  ✓ HTTP accessible (${HTTP_CODE})"
  else
    echo "  ⚠️  HTTP returned: ${HTTP_CODE}"
  fi
  
  echo "Testing HTTPS (port 443):"
  HTTPS_CODE=""
  HTTPS_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -k "https://${PANEL_DOMAIN}" 2>/dev/null || echo "000")
  if [ "${HTTPS_CODE}" = "000" ]; then
    echo "  ❌ Cannot connect (timeout, DNS, or certificate issue)"
  elif [ "${HTTPS_CODE}" = "401" ]; then
    echo "  ✓ HTTPS accessible but requires authentication (${HTTPS_CODE})"
    echo "  → This is expected! Use the admin credentials to log in."
  elif [ "${HTTPS_CODE}" = "200" ]; then
    echo "  ✓ HTTPS accessible (${HTTPS_CODE})"
  else
    echo "  ⚠️  HTTPS returned: ${HTTPS_CODE}"
  fi
else
  echo "⚠️  curl not available for connectivity test"
fi
echo ""

# Summary and recommendations
echo "=== Summary & Recommendations ==="
echo ""
echo "If panel is not accessible, check:"
echo "1. DNS: Ensure ${PANEL_DOMAIN} points to this server's IP"
echo "2. Certificate: Wait for cert-manager to issue certificate (may take 1-5 minutes)"
echo "3. Firewall: Ensure ports 80 and 443 are open"
echo "4. Check certificate status: kubectl get certificate -n platform"
echo "5. Check cert-manager logs: kubectl logs -n cert-manager -l app=cert-manager"
echo "6. Check Traefik logs: kubectl logs -n kube-system -l app.kubernetes.io/name=traefik"
echo "7. Check panel logs: kubectl logs -n platform -l app=panel"
echo ""
echo "To check certificate status:"
echo "  kubectl describe certificate -n platform"
echo "  kubectl get certificaterequest -n platform"
echo ""
echo "To check ingress:"
echo "  kubectl describe ingress panel -n platform"
echo ""
