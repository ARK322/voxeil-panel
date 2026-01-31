# CI Loop Runbook

## Local CI Simulation

Run the CI loop script locally to simulate GitHub Actions integration test:

```bash
# With k3s (full test)
./scripts/ci-loop.sh --max-attempts 2

# Without k3s (uses existing cluster)
./scripts/ci-loop.sh --skip-k3s --max-attempts 2
```

The script will:
1. Run `./voxeil.sh install`
2. Run `./voxeil.sh doctor`
3. Run `./voxeil.sh uninstall --force`
4. Run `./voxeil.sh install` again (idempotency test)
5. Run `./voxeil.sh doctor` again
6. Repeat for `--max-attempts` times

## GitHub Actions Debug Artifacts

If the Integration Test fails in GitHub Actions:

1. Go to the failed workflow run
2. Click "Artifacts" in the top right
3. Download "debug-bundle" artifact
4. Check `debug-bundle.txt` for:
   - Pod status
   - Recent events
   - Deployment descriptions
   - Pod logs (tail 200)

## Self-Healing Guards

The installer now includes automatic fixes:

- **PostgreSQL password sync**: `platform/platform-secrets` POSTGRES_ADMIN_PASSWORD automatically matches `infra-db/postgres-secret` POSTGRES_PASSWORD
- **bind9-tsig secret**: Automatically created in `dns-zone` namespace
- **Webhook readiness**: Waits for cert-manager-webhook and kyverno-admission-controller before app rollout
- **PostgreSQL readiness**: Waits for postgres StatefulSet and service endpoints

## Failure Patterns

Common failure patterns and fixes:

1. **Password authentication failed**: Check postgres password sync in 20-core.sh logs
2. **ImagePullBackOff**: Base images (alpine, postgres, pgadmin) must be pre-imported in CI
3. **Webhook timeout**: Webhook deployments must be ready before app rollout
4. **CrashLoopBackOff**: Check debug bundle logs for root cause

## Debug Bundle Format

Debug bundles use consistent markers:
- `DEBUG BUNDLE START` - Beginning of debug output
- `DEBUG BUNDLE END` - End of debug output

Search for these markers in logs to find failure diagnostics.
