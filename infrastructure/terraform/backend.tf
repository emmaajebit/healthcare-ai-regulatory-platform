terraform {
  backend "s3" {
    bucket     = "healthcare-ai-terraform-state"
    key        = "global/terraform.tfstate"
    region     = "us-east-1"
    encrypt    = true
    kms_key_id = "alias/healthcare-ai-terraform-state"

    # Terraform 1.10 native S3 state locking.
    # Uses conditional PutObject (If-None-Match) to write a <key>.tflock file.
    # Eliminates the DynamoDB table that was previously required for locking.
    use_lockfile = true
  }
}
