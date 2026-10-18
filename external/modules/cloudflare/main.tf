data "cloudflare_zone" "zone" {
  filter = {
    name = "malford.io"
  }
}

# v5 replaced the keyed permission-groups data source with a filterable list.
data "cloudflare_api_token_permission_groups_list" "zone" {
  scope = "com.cloudflare.api.account.zone"
}

locals {
  # one() fails the plan if a name stops resolving to exactly one group,
  # rather than silently issuing a mis-scoped token.
  zone_permission_group_ids = {
    for name in ["Zone Read", "DNS Write"] :
    name => one([
      for pg in data.cloudflare_api_token_permission_groups_list.zone.result :
      pg.id if pg.name == name
    ])
  }

  # external-dns and cert-manager carry the same zone-scoped DNS policy.
  # v5 made permission_groups an ordered list, so this order matches existing
  # state to avoid a cosmetic update that would re-issue the token values.
  dns_token_policies = [{
    effect = "allow"
    permission_groups = [
      { id = local.zone_permission_group_ids["DNS Write"] },
      { id = local.zone_permission_group_ids["Zone Read"] },
    ]
    resources = jsonencode({
      "com.cloudflare.api.account.zone.*" = "*"
    })
  }]
}

resource "random_password" "tunnel_secret" {
  length  = 64
  special = false
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "homelab" {
  account_id    = var.cloudflare_account_id
  name          = "homelab"
  tunnel_secret = base64encode(random_password.tunnel_secret.result)
}

# Not proxied, not accessible. Just a record for auto-created CNAMEs by external-dns.
resource "cloudflare_dns_record" "tunnel" {
  zone_id = data.cloudflare_zone.zone.id
  type    = "CNAME"
  name    = "homelab-tunnel.${data.cloudflare_zone.zone.name}" # v5 wants the FQDN
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  proxied = false
  ttl     = 1 # Auto
}

resource "kubernetes_secret_v1" "cloudflared_credentials" {
  metadata {
    name      = "cloudflared-credentials"
    namespace = "cloudflared"

    annotations = {
      "app.kubernetes.io/managed-by" = "Terraform"
    }
  }

  data = {
    "credentials.json" = jsonencode({
      AccountTag   = var.cloudflare_account_id
      TunnelName   = cloudflare_zero_trust_tunnel_cloudflared.homelab.name
      TunnelID     = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
      TunnelSecret = base64encode(random_password.tunnel_secret.result)
    })
  }
}

resource "cloudflare_api_token" "external_dns" {
  name     = "homelab_external_dns"
  policies = local.dns_token_policies
}

resource "kubernetes_secret_v1" "external_dns_token" {
  metadata {
    name      = "cloudflare-api-token"
    namespace = "external-dns"

    annotations = {
      "app.kubernetes.io/managed-by" = "Terraform"
    }
  }

  data = {
    "value" = cloudflare_api_token.external_dns.value
  }
}

resource "cloudflare_api_token" "cert_manager" {
  name     = "homelab_cert_manager"
  policies = local.dns_token_policies
}

resource "kubernetes_secret_v1" "cert_manager_token" {
  metadata {
    name      = "cloudflare-api-token"
    namespace = "cert-manager"

    annotations = {
      "app.kubernetes.io/managed-by" = "Terraform"
    }
  }

  data = {
    "api-token" = cloudflare_api_token.cert_manager.value
  }
}
