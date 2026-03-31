# Local OpenClaw Config Change (Mac)

After the operator and tailscale ingress are deployed and verified, update
`~/.openclaw/openclaw.json` on your Mac. Only the `gateway` block changes:

**From:**
```json
"gateway": {
  "port": 18789,
  "mode": "local",
  "bind": "lan",
  ...
}
```

**To:**
```json
"gateway": {
  "port": 18789,
  "mode": "remote",
  "remote": {
    "url": "wss://openclaw-gateway.tail811db.ts.net",
    "token": "<value of openclaw-gateway-token from your secret store>"
  },
  "controlUi": {
    "allowedOrigins": [
      "https://openclaw-gateway.tail811db.ts.net",
      "https://matt-16-mbp.tail811db.ts.net"
    ],
    "allowInsecureAuth": false
  },
  "tailscale": {
    "mode": "off",
    "resetOnExit": false
  },
  "nodes": {
    "denyCommands": [
      "camera.snap",
      "camera.clip",
      "screen.record",
      "contacts.add",
      "calendar.add",
      "reminders.add",
      "sms.send"
    ]
  }
}
```

Then stop the local gateway (it's no longer the active one):
```bash
openclaw gateway stop
```

Test the remote connection:
```bash
openclaw health
openclaw status --deep
```

## Rollback

If anything goes wrong, revert `mode` back to `"local"` and run:
```bash
openclaw gateway start
```
