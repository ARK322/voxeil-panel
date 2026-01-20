# DB_ZONE_VERIFICATION

## Contract check (current)
- `POST /sites/:slug/db/enable`
  - Creates role `u_<slug>` and database `db_<slug>` (default).
  - Creates tenant secret `db-conn`.
- `POST /sites/:slug/db/disable`
  - Deletes tenant secret only (reversible).
- `POST /sites/:slug/db/purge` `{confirm:"DELETE"}`
  - Terminates connections, drops db + role, deletes secret (irreversible).
- `GET /sites/:slug/db/status`
  - Returns `secretPresent` and `dbEnabled` state.

## Hardening notes
- Identifier allowlist enforced: `[a-z0-9_]+` for db/user names.
- Admin credentials are read from platform secret env (`POSTGRES_*` / `DB_*`).
- Purge runs `revokeAndTerminate` before drop.
- Password rotation: not automatic yet; future plan is to add a `rotate` endpoint.

## Test checklist

### Build
```
cd apps/controller
npm run build
```

### SQL sanity (pg client)
```
# assumes admin creds from platform secret/env
psql -h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_ADMIN_USER -d $POSTGRES_DB -c "\du"
psql -h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_ADMIN_USER -d $POSTGRES_DB -c "\l"
```

### API verification (example)
```
curl -X POST http://<controller>/sites/<slug>/db/enable -H "X-API-Key: <key>"
curl http://<controller>/sites/<slug>/db/status -H "X-API-Key: <key>"
curl -X POST http://<controller>/sites/<slug>/db/disable -H "X-API-Key: <key>"
curl -X POST http://<controller>/sites/<slug>/db/purge \
  -H "X-API-Key: <key>" -H "Content-Type: application/json" \
  -d '{"confirm":"DELETE"}'
```
