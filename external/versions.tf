terraform {
  required_version = "~> 1.8"

  backend "remote" {
    hostname     = "app.terraform.io"
    organization = "malford-homelab"

    workspaces {
      name = "homelab-external"
    }
  }

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.30.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0.0"
    }

    http = {
      source  = "hashicorp/http"
      version = "~> 3.4.0"
    }
  }
}

provider "cloudflare" {
  email   = var.cloudflare_email
  api_key = var.cloudflare_api_key
}

provider "kubernetes" {
  # Pinned rather than left empty. An empty block falls back to KUBE_CONFIG_PATH,
  # and an unset KUBE_CONFIG_PATH is silent: see the validation on this variable.
  # Plan and apply only ever run interactively from the jump box, so there is no
  # in-cluster service account path to preserve here.
  config_path = var.kubeconfig_path
}
