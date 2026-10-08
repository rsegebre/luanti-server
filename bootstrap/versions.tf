terraform {
  required_version = ">= 1.10.0"

  required_providers {
    linode = {
      source  = "linode/linode"
      version = "4.7.0"
    }
  }
}
