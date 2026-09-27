terraform {
  backend "s3" {
    bucket       = "the-drift-log-tfstate-866149839160"
    key          = "bootstrap/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}