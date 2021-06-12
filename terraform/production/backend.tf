terraform {
  backend "s3" {
    bucket = "badams"
    key    = "badams.tfstate"
    region = "us-east-1"
  }
}
