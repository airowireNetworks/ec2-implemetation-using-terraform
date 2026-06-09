variable "datadog_api_key" {
  type      = string
  sensitive = true
}

variable "datadog_site" {
  type    = string
  default = "datadoghq.com"
}

variable "prod_instance_ids" {
  type = list(string)
}

variable "nonprod_instance_ids" {
  type = list(string)
}
