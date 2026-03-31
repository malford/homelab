# apps/tailscale-operator

Deploys the [Tailscale Kubernetes Operator](https://tailscale.com/kb/1236/kubernetes-operator)
via ArgoCD, using the same pattern as the rest of this repo.

## What this does

- Installs the Tailscale Operator into the `tailscale-operator` namespace
- Watches for `Ingress` resources with `ingressClassName: tailscale`
- Provisions a dedicated tailnet device per ingress with MagicDNS + TLS

The OpenClaw gateway ingress (`apps/openclaw/templates/tailscale-ingress.yaml`)
uses this to expose `wss://openclaw-gateway.tail811db.ts.net` directly to your
tailnet — no nginx WebSocket proxying required.

## Prerequisites (do before committing/syncing)

### 1. Tailscale admin console — ACL tags

At https://login.tailscale.com/admin/acls, add to `tagOwners`:

```json
"tagOwners": {
  "tag:k8s-operator": [],
  "tag:k8s":          ["tag:k8s-operator"],
  "tag:container":    []
}
```

`tag:container` is your existing tag for the subnet router — leave it as-is.

### 2. Tailscale admin console — OAuth client

At https://login.tailscale.com/admin/settings/trust-credentials:

- **Scopes:** Devices Core (write), Auth Keys (write), Services (write)
- **Tag:** `tag:k8s-operator`

### 3. Secret store — add the OAuth credentials

Add these two properties to your `external` secret in the `global-secrets` store
(the same store used by all other apps):

| Property key                        | Value                  |
|-------------------------------------|------------------------|
| `tailscale-operator-client-id`      | OAuth client ID        |
| `tailscale-operator-client-secret`  | OAuth client secret    |

The `ExternalSecret` in `templates/externalsecret.yaml` will pull these into a
`operator-oauth` Kubernetes Secret that the operator reads at startup.

## Verification

```bash
# Operator pod should be running
kubectl get pods -n tailscale-operator

# After openclaw tailscale ingress is applied, a proxy pod appears
kubectl get pods -n openclaw

# Check Tailscale admin console for new devices:
#   tailscale-operator  (tagged tag:k8s-operator)
#   openclaw-gateway    (tagged tag:k8s)

# Test connectivity from your Mac (must be on the tailnet)
curl https://openclaw-gateway.tail811db.ts.net/__openclaw__/health
```

## Local Mac config change

After verifying connectivity, update `~/.openclaw/openclaw.json` — see
`apps/openclaw/LOCAL-CONFIG-CHANGE.md` for the exact diff.
