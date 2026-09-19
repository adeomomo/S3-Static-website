terraform {
  backend "s3" {
    bucket         = "adeomomo-terraform-state"
    key            = "s3-website/terraform.tfstate"
    region         = "ap-southeast-2"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}
