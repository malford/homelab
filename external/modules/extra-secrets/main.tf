resource "kubernetes_secret_v1" "external" {
  metadata {
    name      = var.name
    namespace = var.namespace

    annotations = {
      "app.kubernetes.io/managed-by" = "Terraform"
    }
  }

  data = var.data
}

# State migration: kubernetes_secret -> kubernetes_secret_v1
# Safe to remove after first apply.
moved {
  from = kubernetes_secret.external
  to   = kubernetes_secret_v1.external
}
