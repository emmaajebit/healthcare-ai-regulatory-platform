terraform {
  backend "s3" {
    bucket         = "healthcare-ai-terraform-state"
    key            = "global/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "healthcare-ai-terraform-locks"
    encrypt        = true
    kms_key_id     = "alias/healthcare-ai-terraform-state"
  }
}
