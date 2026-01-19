# Mailcow Zone Plan (Read-Only Design)

This document defines a shared Mailcow zone architecture and the controller-side contracts needed to enable/disable mail per site. No implementation changes are made here.

## A) Architecture

- **Shared mail zone in its own namespace**: Mailcow runs once in the `mail-zone` namespace as a shared service.
- **Tenant namespaces stay isolated**: Tenant namespaces do not run mail pods. Mail domains/accounts are managed through the Mailcow API only.
- **DNS requirements (per mail domain)**:
  - `MX` record pointing to the Mailcow host (priority 10 or preferred).
  - `A/AAAA` record for `mail.<domain>` (or chosen hostname) pointing to Mailcow ingress IP.
  - `TXT` SPF: `v=spf1 mx -all` (or `include:` if using upstream relay).
  - `TXT` DKIM: selector record published from Mailcow (e.g., `default._domainkey.<domain>`).
  - `TXT` DMARC: `_dmarc.<domain>` with policy (start with `p=quarantine` or `p=none`).
  - `CNAME` autoconfig: `autoconfig.<domain>` -> `mail.<domain>`.
  - `CNAME` autodiscover: `autodiscover.<domain>` -> `mail.<domain>`.
- **Network/Ingress**:
  - SMTP: `25`, SMTPS `465`, Submission `587`.
  - IMAP: `143` and IMAPS `993`.
  - POP3: `110` and POP3S `995` (optional if enabled).
  - HTTP/HTTPS: `80/443` for Mailcow UI/API and `autoconfig`/`autodiscover` endpoints.
  - **k3s/Traefik**: some of these are TCP entrypoints, not HTTP; plan explicit TCP entrypoints for 25/465/587/143/993/110/995.

## B) Integration contracts (controller side)

No implementation yet; define controller endpoints only.

**Endpoints**:
- `POST /sites/:slug/mail/enable` `{}`
- `POST /sites/:slug/mail/disable` `{}`

**Optional future**:
- `POST /sites/:slug/mail/mailboxes` `{ localPart, password, quotaMb }`
- `GET /sites/:slug/mail/status`

**Required controller env vars**:
- `MAILCOW_API_URL` (e.g., `https://mail.example.com/api/v1`)
- `MAILCOW_API_KEY` (admin or restricted API key)
- `MAILCOW_HOSTNAME` (optional; explicit hostname for UI links/records)

**Secrets handling**:
- Store secrets in a Kubernetes `Secret` under the platform namespace.
- Controller reads via env vars; do not place secrets in config maps or code.

## C) Namespace-annotation "state" keys (temporary DB)

Use existing annotation prefix convention (e.g., `voxeil.io` or similar):
- `<prefix>/mail-enabled`
- `<prefix>/mail-provider`
- `<prefix>/mail-domain`
- `<prefix>/mail-status`
- `<prefix>/mail-last-error`

## D) Infra plan (later implementation steps)

- **Manifests location**: `infra/k8s/mailcow/` (deployments, services, ingress/traefik TCP, secrets references).
- **Installer**: add an optional "install mail zone" step to provision Mailcow and required ingress/TCP entrypoints.
- **RBAC**: none required for mail operations; controller uses external Mailcow API only.
- **UI exposure**: Mailcow admin UI should be admin-only; restrict via ingress auth or IP allowlist.

## E) Safety / operational notes

- **Rate limits & reputation**: enforce sensible sending limits; protect shared IP reputation.
- **rDNS & deliverability**: ensure rDNS aligns with `mail.<domain>`; misalignment hurts deliverability.
- **Port 25 blocks**: many VPS providers block outbound 25; plan for relay or allow-listing.
- **Backups**: include mailbox, DB, and config backups in a later phase.
