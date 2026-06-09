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
/etc/datadog-agent/datadog.yaml.bak || true

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

listeners:
  - name: docker

config_providers:
  - name: docker
    polling: true

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
# Docker Monitoring
###########################################

if command -v docker >/dev/null 2>&1; then

    echo "Docker detected"

    mkdir -p /etc/datadog-agent/conf.d/docker.d

    cat > /etc/datadog-agent/conf.d/docker.d/conf.yaml << EOF
init_config:

instances:
  - url: "unix:///var/run/docker.sock"
EOF

    usermod -aG docker dd-agent || true

fi

###########################################
# Linux Log Permissions
###########################################

usermod -aG adm dd-agent || true

###########################################
# Network Monitoring
###########################################

cat > /etc/datadog-agent/system-probe.yaml << EOF
system_probe_config:
  enabled: true

network_config:
  enabled: true

runtime_security_config:
  enabled: true
EOF

###########################################
# System Probe Permissions
###########################################

if [ -f /opt/datadog-agent/embedded/bin/system-probe ]; then

    setcap cap_sys_admin,cap_net_admin,cap_net_raw+ep \
    /opt/datadog-agent/embedded/bin/system-probe

fi

###########################################
# Restart Services
###########################################

systemctl restart datadog-agent || true
systemctl restart datadog-agent-process || true
systemctl restart datadog-agent-sysprobe || true
systemctl restart datadog-agent-security || true

###########################################
# Validation
###########################################

sleep 20

datadog-agent status || true

echo "Datadog Agent Installation Completed Successfully"
