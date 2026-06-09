output "ssm_document_name" {
  value = aws_ssm_document.datadog_agent_install.name
}

output "prod_instances" {
  value = length(var.prod_instance_ids)
}

output "nonprod_instances" {
  value = length(var.nonprod_instance_ids)
}
