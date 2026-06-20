mock_data "aws_availability_zones" {
  defaults = {
    names = ["us-east-1a"]
  }
}

mock_data "aws_ami" {
  defaults = {
    id = "ami-0agentstacktest"
  }
}

mock_resource "aws_instance" {
  defaults = {
    id        = "i-agentstacktest"
    public_ip = "203.0.113.10"
  }
}

mock_resource "aws_ebs_volume" {
  defaults = {
    id = "vol-agentstacktest"
  }
}
