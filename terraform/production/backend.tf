terraform {
  backend "s3" {
    bucket     = "badams"
    key        = "badams.tfstate"
    region     = "us-east-1"
    access_key = "AKIAW6SGPZFHSCMTXHEE"
    secret_key = "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"
  }
}
