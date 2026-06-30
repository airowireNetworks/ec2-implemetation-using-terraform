#!/bin/bash
 
set -e
 
echo "Starting Datadog Agent Installation..."
 
###########################################
# Variables — fill these before deploying
###########################################
 
DD_API_KEY="{{DDAPIKEY}}"
DD_SITE="{{DDSITE}}"
ENVIRONMENT="{{ENVIRONMENT}}"
 
# ── APPLICATION LOG PLACEHOLDERS ─────────────────────────────────────────────
# Fill these in before running. If placeholders are not replaced,
# the app log section will be written as comments (safe — no agent errors).
APP_NAME="{{APP_NAME}}"                       # e.g. my-api
APP_LOG_PATH="{{APP_LOG_PATH}}"               # e.g. /var/log/myapp/app.log
APP_ERROR_LOG_PATH="{{APP_ERROR_LOG_PATH}}"   # e.g. /var/log/myapp/error.log
APP_ACCESS_LOG_PATH="{{APP_ACCESS_LOG_PATH}}" # e.g. /var/log/nginx/access.log
# ─────────────────────────────────────────────────────────────────────────────
 
export DD_API_KEY
export DD_SITE
 
###########################################
# SSM AGENT PROTECTION
# Ensure SSM is running before any changes.
# EXIT TRAP guarantees SSM is restored even
# if this script fails or exits early.
###########################################
 
systemctl enable amazon-ssm-agent || true
systemctl start amazon-ssm-agent  || true
echo "SSM Agent status at start: $(systemctl is-active amazon-ssm-agent || true)"
 
trap 'echo "--- EXIT TRAP: restoring SSM agent ---"; systemctl start amazon-ssm-agent || true; echo "SSM status: $(systemctl is-active amazon-ssm-agent || true)"' EXIT
 
###########################################
# Install Datadog Agent
###########################################
 
DD_API_KEY="$DD_API_KEY" \
DD_SITE="$DD_SITE" \
bash -c "$(curl -fsSL https://install.datadoghq.com/scripts/install_script_agent7.sh)"
 
###########################################
# Backup Existing Configuration
###########################################
 
cp /etc/datadog-agent/datadog.yaml \
   /etc/datadog-agent/datadog.yaml.bak || true
 
###########################################
# Configure Datadog Agent (datadog.yaml)
# FIX: Docker listeners only added when
# Docker is actually present, preventing
# startup warnings that mask log errors.
###########################################
 
# Base config — always written
cat > /etc/datadog-agent/datadog.yaml << EOF
api_key: $DD_API_KEY
site: $DD_SITE
 
logs_enabled: true
 
logs_config:
  container_collect_all: true
  use_http: true
 
process_config:
  process_collection:
    enabled: true
 
tags:
  - env:$ENVIRONMENT
  - monitoring:datadog
  - managed_by:terraform
EOF
 
# Append Docker config only if Docker socket exists
if [ -S /var/run/docker.sock ]; then
    cat >> /etc/datadog-agent/datadog.yaml << EOF
 
listeners:
  - name: docker
 
config_providers:
  - name: docker
    polling: true
EOF
    echo "Docker detected — Docker listeners added to datadog.yaml"
else
    echo "Docker not detected — skipping Docker listeners in datadog.yaml"
fi
 
###########################################
# Journald / Systemd Log Collection
# FIX: Added path to journal socket so
# Datadog reliably finds it on Amazon Linux
###########################################
 
mkdir -p /etc/datadog-agent/conf.d/journald.d
 
# Detect journal path (Amazon Linux 2 vs 2023)
JOURNAL_PATH="/run/log/journal"
if [ ! -d "$JOURNAL_PATH" ]; then
    JOURNAL_PATH="/var/log/journal"
fi
 
cat > /etc/datadog-agent/conf.d/journald.d/conf.yaml << EOF
logs:
  - type: journald
    path: $JOURNAL_PATH
    service: amazon-linux
    source: systemd
    include_units:
      - sshd.service
      - sudo.service
      - crond.service
      - auditd.service
EOF
 
echo "Journald config written — journal path: $JOURNAL_PATH"
 
###########################################
# File-Based System + Audit Log Collection
# Captures: messages, secure, dmesg, audit
###########################################
 
mkdir -p /etc/datadog-agent/conf.d/host.d
 
cat > /etc/datadog-agent/conf.d/host.d/conf.yaml << EOF
logs:
  # General system messages
  - type: file
    path: /var/log/messages
    service: system
    source: linux
    tags:
      - log_type:system
 
  # Authentication, SSH, sudo logs
  - type: file
    path: /var/log/secure
    service: security
    source: linux
    tags:
      - log_type:auth
 
# General system messages
  - type: file
    path: /var/log/syslog
    service: system
    source: linux
    tags:
      - log_type:system
 
# Authentication, SSH, sudo logs
  - type: file
    path: /var/log/auth.log
    service: security
    source: linux
    tags:
      - log_type:auth
 
 
  # Kernel and boot logs
  - type: file
    path: /var/log/dmesg
    service: kernel
    source: linux
    tags:
      - log_type:kernel
 
  # Audit logs — syscall, file access, privilege escalation
  - type: file
    path: /var/log/audit/audit.log
    service: audit
    source: auditd
    tags:
      - log_type:audit
EOF
 
###########################################
# Application Log Collection
# FIX: Placeholders are checked before
# writing. If not replaced, app log blocks
# are written as YAML comments so the agent
# does NOT try to tail non-existent paths.
###########################################
 
mkdir -p /etc/datadog-agent/conf.d/app.d
 
# Check if placeholders were actually replaced
APP_LOGS_CONFIGURED=true
if [[ "$APP_LOG_PATH" == *"{{"* ]] || [[ "$APP_NAME" == *"{{"* ]]; then
    APP_LOGS_CONFIGURED=false
    echo "WARN: APP_LOG_PATH / APP_NAME placeholders not replaced — app log collection disabled until you fill them in"
fi
 
if [ "$APP_LOGS_CONFIGURED" = true ]; then
    cat > /etc/datadog-agent/conf.d/app.d/conf.yaml << EOF
logs:
 
  # General application log
  - type: file
    path: $APP_LOG_PATH
    service: $APP_NAME
    source: custom
    tags:
      - log_type:application
      - app:$APP_NAME
EOF
 
    # Add error log only if placeholder was replaced
    if [[ "$APP_ERROR_LOG_PATH" != *"{{"* ]]; then
        cat >> /etc/datadog-agent/conf.d/app.d/conf.yaml << EOF
 
  # Application error log
  - type: file
    path: $APP_ERROR_LOG_PATH
    service: $APP_NAME
    source: custom
    tags:
      - log_type:error
      - app:$APP_NAME
EOF
    fi
 
    # Add access log only if placeholder was replaced
    if [[ "$APP_ACCESS_LOG_PATH" != *"{{"* ]]; then
        cat >> /etc/datadog-agent/conf.d/app.d/conf.yaml << EOF
 
  # Application access log (change source to apache/gunicorn etc. if needed)
  - type: file
    path: $APP_ACCESS_LOG_PATH
    service: $APP_NAME
    source: nginx
    tags:
      - log_type:access
      - app:$APP_NAME
EOF
    fi
 
    echo "App log collection configured for: $APP_NAME"
 
else
    # Write a safe commented-out template so the file exists but causes no errors
    cat > /etc/datadog-agent/conf.d/app.d/conf.yaml << EOF
# App log collection not yet configured.
# Replace the placeholders below and remove the comment markers (#) to enable.
#
# logs:
#   - type: file
#     path: /var/log/YOUR_APP/app.log
#     service: YOUR_APP_NAME
#     source: custom
#     tags:
#       - log_type:application
#       - app:YOUR_APP_NAME
#
#   - type: file
#     path: /var/log/YOUR_APP/error.log
#     service: YOUR_APP_NAME
#     source: custom
#     tags:
#       - log_type:error
#       - app:YOUR_APP_NAME
#
#   - type: file
#     path: /var/log/nginx/access.log
#     service: YOUR_APP_NAME
#     source: nginx
#     tags:
#       - log_type:access
#       - app:YOUR_APP_NAME
EOF
fi
 
###########################################
# Docker Monitoring
###########################################
 
if [ -S /var/run/docker.sock ]; then
    mkdir -p /etc/datadog-agent/conf.d/docker.d
    cat > /etc/datadog-agent/conf.d/docker.d/conf.yaml << EOF
init_config:
 
instances:
  - url: "unix:///var/run/docker.sock"
EOF
    echo "Docker monitoring config written"
else
    echo "Docker not detected — skipping docker.d config"
fi
 
###########################################
# Group Memberships for Log File Access
###########################################
 
# Docker socket access
if getent group docker >/dev/null; then
    usermod -aG docker dd-agent || true
fi
 
# Journald access
if getent group systemd-journal >/dev/null; then
    usermod -aG systemd-journal dd-agent || true
fi
 
# adm group — read access to /var/log/messages,
# /var/log/secure, /var/log/audit/audit.log
usermod -aG adm dd-agent || true
 
###########################################
# Auditd Setup + Permissions
# FIX: Removed "auditctl -w -p r" which was
# incorrectly watching audit.log for reads,
# flooding the log with self-read events.
# Permissions are set once here and held via
# logrotate postrotate script instead.
###########################################
 
systemctl enable auditd || true
systemctl start auditd  || true
 
# Grant dd-agent (adm group) access to audit dir + log
if [ -d /var/log/audit ]; then
    chmod g+rx /var/log/audit || true
fi
 
if [ -f /var/log/audit/audit.log ]; then
    chmod g+r /var/log/audit/audit.log || true
fi
 
# Persist permissions across auditd log rotations using logrotate postrotate
# (safe alternative to the incorrect auditctl -w -p r approach)
if [ -f /etc/logrotate.d/audit ]; then
    # Add a postrotate hook to re-apply group-read after each rotation
    if ! grep -q "chmod g+r" /etc/logrotate.d/audit; then
        sed -i '/postrotate/a\        chmod g+r /var/log/audit/audit.log || true' \
            /etc/logrotate.d/audit 2>/dev/null || true
    fi
fi
 
###########################################
# Application Log Directory Permissions
# FIX: Only runs if APP_LOG_PATH was
# actually replaced (not a placeholder).
# No chown — chmod on log files only.
###########################################
 
if [ "$APP_LOGS_CONFIGURED" = true ]; then
    APP_LOG_DIR=$(dirname "$APP_LOG_PATH")
    if [ -d "$APP_LOG_DIR" ]; then
        chmod g+rx "$APP_LOG_DIR" || true
        find "$APP_LOG_DIR" -maxdepth 1 -name "*.log" -exec chmod g+r {} \; 2>/dev/null || true
        echo "App log dir permissions set: $APP_LOG_DIR"
    fi
fi
 
###########################################
# Network Monitoring + Runtime Security
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
# System Probe Capabilities
###########################################
 
if [ -f /opt/datadog-agent/embedded/bin/system-probe ]; then
    setcap cap_sys_admin,cap_net_admin,cap_net_raw+ep \
    /opt/datadog-agent/embedded/bin/system-probe || true
fi
 
###########################################
# Enable All Services
###########################################
 
systemctl enable auditd                  || true
systemctl enable datadog-agent           || true
systemctl enable datadog-agent-process   || true
systemctl enable datadog-agent-sysprobe  || true
systemctl enable datadog-agent-security  || true
 
###########################################
# Refresh Group Membership
# Stop agent cleanly so adm + systemd-journal
# group memberships apply on next start
###########################################
 
systemctl stop datadog-agent 2>/dev/null || true
sleep 5
 
###########################################
# Restart All Services
# auditd first — log file must exist before
# Datadog tries to tail it
###########################################
 
systemctl restart auditd                 || true
systemctl restart datadog-agent          || true
systemctl restart datadog-agent-process  || true
systemctl restart datadog-agent-sysprobe || true
systemctl restart datadog-agent-security || true
 
###########################################
# Validation
###########################################
 
sleep 20
 
echo ""
echo "===== Datadog Agent Status ====="
datadog-agent status || true
 
echo ""
echo "===== Log Agent Status ====="
datadog-agent status | grep -A40 "Logs Agent" || true
 
echo ""
echo "===== Log Sources Being Tailed ====="
datadog-agent status | grep -E "(Type: file|Type: journald|Path:|Status:)" || true
 
echo ""
echo "===== Audit Log Tail (last 5 lines) ====="
tail -5 /var/log/audit/audit.log || echo "WARN: audit.log not accessible yet"
 
echo ""
echo "===== App Log Tail ====="
if [ "$APP_LOGS_CONFIGURED" = true ]; then
    tail -5 "$APP_LOG_PATH" 2>/dev/null || echo "WARN: App log not found at $APP_LOG_PATH"
else
    echo "SKIP: App log placeholders not yet replaced"
fi
 
echo ""
echo "===== dd-agent Group Membership ====="
id dd-agent || true
 
echo ""
echo "===== Log File Permissions ====="
ls -la /var/log/audit/audit.log 2>/dev/null || echo "audit.log not found"
ls -la /var/log/messages        2>/dev/null || echo "messages not found"
ls -la /var/log/secure          2>/dev/null || echo "secure not found"
[ "$APP_LOGS_CONFIGURED" = true ] && ls -la "$APP_LOG_PATH" 2>/dev/null || true
 
echo ""
echo "===== Journald Path Used ====="
echo "$JOURNAL_PATH"
 
echo ""
echo "===== Config Files Written ====="
ls -la /etc/datadog-agent/conf.d/journald.d/conf.yaml || true
ls -la /etc/datadog-agent/conf.d/host.d/conf.yaml     || true
ls -la /etc/datadog-agent/conf.d/app.d/conf.yaml      || true
ls -la /etc/datadog-agent/conf.d/docker.d/conf.yaml 2>/dev/null || echo "docker.d skipped (no Docker)"
 
echo ""
echo "===== SSM Agent Final Status ====="
systemctl is-active amazon-ssm-agent || true
 
echo ""
echo "Datadog Agent Installation Completed Successfully"
