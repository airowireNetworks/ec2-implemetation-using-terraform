#!/bin/bash

set -e

echo "Starting Datadog Agent Installation..."

DD_API_KEY="{{DDAPIKEY}}"
DD_SITE="{{DDSITE}}"
ENVIRONMENT="{{ENVIRONMENT}}"

export DD_API_KEY
export DD_SITE

###########################################
# Install Datadog Agent
###########################################

DD_API_KEY="$DD_API_KEY" \
DD_SITE="$DD_SITE" \
bash -c "$(curl -fsSL https://install.datadoghq.com/scripts/install_script_agent7.sh)"

###########################################
# Backup Existing Config
###########################################

cp /etc/datadog-agent/datadog.yaml \
/etc/datadog-agent/datadog.yaml.bak 2>/dev/null || true

###########################################
# Main Datadog Configuration
###########################################

cat > /etc/datadog-agent/datadog.yaml << EOF
api_key: $DD_API_KEY
site: $DD_SITE

logs_enabled: true

logs_config:
  container_collect_all: true

process_config:
  process_collection:
    enabled: true

tags:
  - env:$ENVIRONMENT
  - monitoring:datadog
  - managed_by:terraform
EOF

###########################################
# Linux Log Collection
###########################################

mkdir -p /etc/datadog-agent/conf.d/linux.d

cat > /etc/datadog-agent/conf.d/linux.d/conf.yaml << EOF
logs:
  - type: file
    path: /var/log/syslog
    service: ubuntu
    source: syslog

  - type: file
    path: /var/log/auth.log
    service: ssh
    source: ssh
EOF

###########################################
# Docker Monitoring (Optional)
###########################################

if command -v docker >/dev/null 2>&1; then

    echo "Docker detected - enabling Docker integration"

    mkdir -p /etc/datadog-agent/conf.d/docker.d

    cat > /etc/datadog-agent/conf.d/docker.d/conf.yaml << EOF
init_config:

instances:
  - url: "unix:///var/run/docker.sock"
EOF

    usermod -aG docker dd-agent || true

else

    echo "Docker not installed - skipping Docker integration"

fi

###########################################
# Linux Log Permissions
###########################################

usermod -aG adm dd-agent || true

###########################################
# Restart Services
###########################################

systemctl restart datadog-agent || true

###########################################
# Validation
###########################################

sleep 20

datadog-agent status || true

echo "Datadog Agent Installation Completed Successfully"
