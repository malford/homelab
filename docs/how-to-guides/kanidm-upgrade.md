# Upgrade Kanidm

Kanidm cannot skip minor versions. A server reads a database at most one domain
level behind its own, so going 1.3 to 1.5 leaves a DL7 database that a DL9
server refuses to migrate. Getting from 1.3.3 to 1.11.2 is eight separate
upgrades, each with its own gate.

!!! danger "There is no downgrade"

    Migrations run in a single transaction, which gives two very different
    failure modes:

    - **Migration refused, pod will not start** — the database is untouched at
      the old level. Revert the tag commit and Argo rolls back.
    - **Migration committed, then something downstream breaks** — reverting the
      tag is *not* a rollback. A 1.4 server cannot open a DL8 database. The only
      way back is restoring `data-kanidm-0` from VolSync.

    That second case is why the backup step runs on every hop, not just the
    first.

## What depends on this

The chain is `kanidm` → `dex` (OIDC connector on
`https://auth.malford.io/oauth2/openid/dex`) → the `grafana-sso` and `gitea`
static clients. Nothing in the repo consumes LDAP on 636 despite the port being
exposed, so the smoke test is the web login, then Grafana SSO, then Gitea SSO.

The StatefulSet is a single replica, so every hop costs a few minutes of real
SSO downtime.

## The ladder

`1.3.3` → `1.4.6` → `1.5.0` → `1.6.4` → `1.7.4` → `1.8.6` → `1.9.4` →
`1.10.5` → `1.11.2`

!!! info "Current position"

    `1.4.6` at DL8 since 2026-10-30 — hop 1 of 8 done, verified by web login,
    Grafana SSO and Gitea SSO. Next is `1.5.0`, whose `domain upgrade-check` is
    already clean, so that hop is a tag bump plus the cookie caveat below.

Confirm the latest patch in a minor when you reach it. Renovate's ceiling in
`renovate.json5` is raised one minor per hop by hand, which is what keeps a
jump-to-latest PR from ever appearing.

Hops that need more than a tag bump:

| Hop | Gate |
| --- | ---- |
| 1.4 | OAuth2 strict redirect URI enforcement — cleared 2026-10-30, see preflight |
| 1.5 | Cookie handling changed; clear browser cookies if login misbehaves |
| 1.6 | `server.toml` must gain `version = "2"`. Commit it with the tag bump |
| 1.7 | OpenSSL to rustls; OAuth2 client IDs forced lowercase (`dex` already is) |
| 1.8 | IPv4-in-IPv6 address canonicalisation. We run `trust_x_forward_for = true`, so recheck the client IPs nginx forwards |
| 1.9 | `--output json` removed from `kanidmd`, which breaks `scripts/hacks` (`recover-account --output json`). Fix the script on this hop |
| 1.10 | Full OpenSSL removal in favour of aws-lc-rs. The `kanidm-selfsigned` cert is `dnsNames: [home.arpa]` with the [issues/1227](https://github.com/kanidm/kanidm/issues/1227) TODO still open, so this is the hop most likely to reject it |
| 1.11 | Passwords capped at 128 characters |

## Preflight (done 2026-10-30)

!!! warning "This comes back after a rebootstrap"

    `scripts/hacks` is still unfixed, so re-running it recreates a
    non-compliant dex client and re-fails the 1.4 gate. Keep this section until
    `setup_kanidm_oauth_app` registers the redirect URI itself.

The 1.4 gate fails on a stock install, because `scripts/hacks` registers the dex
client's callback as the landing URL rather than as a validated redirect URI:

```
upgrade_item : oauth2 strict redirect uri enforcement  → FAIL
  affected_entry : dex@auth.malford.io
```

Clear it before the first hop:

```sh
./scripts/kanidm-reset-password idm_admin
kanidm login --url https://auth.malford.io --name idm_admin
kanidm system oauth2 show dex --url https://auth.malford.io --name idm_admin
```

If `https://dex.malford.io/callback` is not listed as a redirect URI, add it,
then turn on enforcement:

```sh
kanidm system oauth2 add-redirect-uri dex https://dex.malford.io/callback \
  --url https://auth.malford.io --name idm_admin
kanidm system oauth2 enable-strict-redirect-uri dex \
  --url https://auth.malford.io --name idm_admin
```

!!! warning "Match the client to the server"

    The `kanidm` CLI refuses a server on a different minor, and the server image
    ships only `kanidmd` — there is no client binary in the pod. Either install a
    version-matched client for each hop, or run the client out of a matching
    `docker.io/kanidm/tools` container.

    CLI sessions are also short-lived, so expect to log in again as you climb.
    Homebrew's `kanidm` on the Mac tracks latest (1.11.2), so it stays useless
    until the final hop.

!!! warning "`-H` takes the origin, not a UI path"

    Always `-H https://auth.malford.io`. Pointed at a page such as
    `/ui/login`, `login` still succeeds and then every other command returns a
    bare `EmptyResponse`. Avoid the flag entirely with a client config inside
    the tools container:

    ```sh
    printf 'uri = "https://auth.malford.io"\n' > ~/.config/kanidm
    ```

## Per hop

**1. Gate.** Any `FAIL` here means the *next* upgrade will refuse. This is a
read-only operation and safe against a running server:

```sh
kubectl exec -n kanidm sts/kanidm -- kanidmd domain upgrade-check
```

**2. Backup.** Confirm the VolSync `kanidm` ReplicationSource has a recent
`status.lastSyncTime`:

```sh
kubectl get replicationsource -n kanidm kanidm -o yaml | grep -A5 'status:'
```

!!! danger "Never add `trigger.manual` to force a backup"

    A leftover manual trigger kills the schedule permanently while Argo keeps
    reporting Synced. To get a fresh copy outside the window, take an ad-hoc
    `VolumeSnapshot` of `data-kanidm-0` by hand instead. See
    [backup and restore](backup-and-restore.md).

Note that `kanidmd database backup` is offline-only, so the VolSync snapshot is
the practical safety net.

**3. Config-test the new binary before it serves.** Worth doing on every hop and
non-negotiable on 1.6 and 1.10. Scale the StatefulSet to zero, run a one-shot pod
on the new tag mounting the same PVC and ConfigMap, then scale back:

```sh
kubectl scale sts -n kanidm kanidm --replicas 0
# one-shot pod on the new tag, mounting data-kanidm-0 and the config ConfigMap
kanidmd configtest
kanidmd domain upgrade-check
kubectl scale sts -n kanidm kanidm --replicas 1
```

**4. Ship.** Bump `tag:` in `platform/kanidm/values.yaml` together with that
hop's config change, then let Argo sync:

```sh
git push origin main && git push gitea main
```

**5. Verify.** The domain level must have gone up by exactly one:

```sh
kubectl exec -n kanidm sts/kanidm -- kanidmd domain show
```

Then the web login at `auth.malford.io`, Grafana SSO, and Gitea SSO.

**6. Raise the Renovate ceiling** in `renovate.json5` to the next minor, so the
following hop is the only one it can offer.
