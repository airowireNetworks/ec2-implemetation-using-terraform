resource "aws_ssm_document" "datadog_agent_install" {

  name          = "Datadog-Agent-Install"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2"

    parameters = {
      DDAPIKEY = {
        type = "String"
      }

      DDSITE = {
        type = "String"
      }

      ENVIRONMENT = {
        type = "String"
      }
    }

    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "InstallDatadog"

        inputs = {
          runCommand = split(
            "\n",
            file("${path.module}/scripts/install_datadog.sh")
          )
        }
      }
    ]
  })
}
