variable "name_prefix" { 
  default = "demo"
}

variable "name" {
  default = "jenkins"
}

variable "vpc_id" { 
  type = string
}

variable "private_subnet_ids" { 
  type = list(string)
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "memory" {
  default = 2048
}

variable "cpu" {
  default = 1024
}

variable "port" { 
  default = 8080
}

variable "home" {
  default = "jenkins_home"
}

variable "image" {
  default = "jenkins/jenkins:lts"
}

variable "domain" {        
  type = string
}

variable "alb_healthy_http_codes" {
  default = "200-399"
}

variable "route53_zone_id" {
  type = string
}

