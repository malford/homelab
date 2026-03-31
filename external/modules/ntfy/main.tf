resource "kubernetes_secret_v1" "ntfy_auth" {
  metadata {
    name      = "webhook-transformer"
    namespace = "monitoring-system"

    annotations = {
      "app.kubernetes.io/managed-by" = "Terraform"
    }
  }

  data = {
    NTFY_URL   = var.auth.url
    NTFY_TOPIC = var.auth.topic
  }
}

# State migration: kubernetes_secret -> kubernetes_secret_v1
# Safe to remove after first apply.
moved {
  from = kubernetes_secret.ntfy_auth
  to   = kubernetes_secret_v1.ntfy_auth
}
