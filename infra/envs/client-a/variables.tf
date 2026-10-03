variable "region" {
  type = string
}

variable "aws_profile" {
  type = string
}

variable "project_slug" {
  type    = string
  default = "sovran"
}

variable "client_slug" {
  type    = string
  default = "alpha"
}

variable "client_account_id" {
  type        = string
  description = "Expected client account ID (sanity check)."
}

variable "vpc_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "endpoint_service_name" {
  type        = string
  description = "From reference terraform output client_a_endpoint_service_name."
}

variable "agent_port" {
  type    = number
  default = 8080
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}
