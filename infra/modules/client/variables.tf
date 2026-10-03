variable "project_slug" {
  type = string
}

variable "region" {
  type = string
}

variable "client_slug" {
  type = string
}

variable "vpc_cidr" {
  type        = string
  description = "Client VPC CIDR (must not need to peer with reference)."
  default     = "10.10.0.0/16"
}

variable "endpoint_service_name" {
  type        = string
  description = "PrivateLink service name from reference-client (com.amazonaws.vpce...)."
}

variable "agent_port" {
  type    = number
  default = 8080
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "tags" {
  type    = map(string)
  default = {}
}
