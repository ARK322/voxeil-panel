# MAILCOW_CONTRACT

## Contract (site-scoped)
- `POST /sites/:slug/mail/enable` `{domain}`
- `POST /sites/:slug/mail/disable`
- `POST /sites/:slug/mail/purge` `{confirm:"DELETE"}`
- `GET /sites/:slug/mail/status`
- `GET /sites/:slug/mail/mailboxes`
- `POST /sites/:slug/mail/mailboxes` `{localPart,password,quotaMb?}`
- `DELETE /sites/:slug/mail/mailboxes/:address`
- `GET /sites/:slug/mail/aliases`
- `POST /sites/:slug/mail/aliases` `{sourceLocalPart,destination,active?}`
- `DELETE /sites/:slug/mail/aliases/:source`

## Behavior notes
- Disable is reversible (domain stays, Mailcow domain is set inactive).
- Purge is destructive (domain + mailboxes + aliases removed).
- Status returns `mailEnabled` plus live Mailcow active flag.

## Wiring (installer/env)
- Controller expects `MAILCOW_API_URL` + `MAILCOW_API_KEY` in `platform-secrets`.
- `MAILCOW_VERIFY_TLS` defaults to `true`; set `false` only if needed for self-signed Mailcow.

## Test checklist
```
cd apps/controller
npm run build

# Enable
curl -X POST http://<controller>/sites/<slug>/mail/enable \
  -H "X-API-Key: <key>" -H "Content-Type: application/json" \
  -d '{"domain":"example.com"}'

# Mailbox create/list/delete
curl -X POST http://<controller>/sites/<slug>/mail/mailboxes \
  -H "X-API-Key: <key>" -H "Content-Type: application/json" \
  -d '{"localPart":"hello","password":"secret","quotaMb":512}'
curl http://<controller>/sites/<slug>/mail/mailboxes -H "X-API-Key: <key>"
curl -X DELETE http://<controller>/sites/<slug>/mail/mailboxes/hello@example.com \
  -H "X-API-Key: <key>"

# Alias create/list/delete
curl -X POST http://<controller>/sites/<slug>/mail/aliases \
  -H "X-API-Key: <key>" -H "Content-Type: application/json" \
  -d '{"sourceLocalPart":"info","destination":"dest@example.net","active":true}'
curl http://<controller>/sites/<slug>/mail/aliases -H "X-API-Key: <key>"
curl -X DELETE http://<controller>/sites/<slug>/mail/aliases/info@example.com \
  -H "X-API-Key: <key>"

# Disable / Purge
curl -X POST http://<controller>/sites/<slug>/mail/disable -H "X-API-Key: <key>"
curl -X POST http://<controller>/sites/<slug>/mail/purge \
  -H "X-API-Key: <key>" -H "Content-Type: application/json" \
  -d '{"confirm":"DELETE"}'
```
