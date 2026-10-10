variable "cloudflare_email" {
  type = string
}

variable "cloudflare_api_key" {
  type      = string
  sensitive = true
}

variable "cloudflare_account_id" {
  type = string
}

variable "kubeconfig_path" {
  type        = string
  description = "Path to the kubeconfig terraform authenticates with. Defaults to the one metal/ bootstrap writes, relative to this directory."
  default     = "../metal/kubeconfig.yaml"

  # This is the point of the variable. Without a usable kubeconfig the
  # kubernetes provider does not fail - it reads every object as not-found,
  # so terraform plans `create` for secrets that already exist and drops any
  # whose config was removed straight out of state instead of destroying it.
  # A wrong plan is far more dangerous than a refused one, so refuse early.
  validation {
    condition     = fileexists(var.kubeconfig_path)
    error_message = "No kubeconfig at ${var.kubeconfig_path} - terraform would plan against an empty cluster."
  }
}

variable "extra_secrets" {
  type        = map(string)
  description = "Key-value pairs of extra secrets that cannot be randomly generated (e.g. third party API tokens)"
  sensitive   = true
  default     = {}
}
