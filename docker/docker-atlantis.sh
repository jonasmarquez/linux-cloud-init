#!/bin/bash

set -e

##--------------------------------------------------------------------
# CONFIGURATION OF AWS EFS VOL (PERSISTENT DATA)
sudo mkdir -p /mnt/nfs
echo "${nfs_id}.efs.${aws_region}.amazonaws.com:/ /mnt/nfs nfs4 nfsvers=4.1,auto 0 0" | sudo tee -a /etc/fstab
sudo mount -a
sudo mkdir -p /mnt/nfs/${entity}/services/${service}/data
sudo mkdir -p /mnt/nfs/${entity}/services/${service}/config
sudo chmod -R 755 /mnt/nfs/*
sudo chown -R systemd-network:ubuntu /mnt/nfs/*

##--------------------------------------------------------------------
# CREATE AUTH-APP-ROLE IN VAULT WITH ROLE
export VAULT_ADDR="https://${vault_addr}:8200"
export VAULT_SKIP_VERIFY=true
vault login ${vault_root_token}
vault write -force auth/aws/role/${app_role} auth_type=iam bound_iam_principal_arn="${iam_role_arn_atlantis_cluster}" policies=${service}-app-pol ttl=24h
sleep 180

##--------------------------------------------------------------------
# CONFIGURATION VAULT-AGENT
sudo mkdir -pm 0755 /etc/vault.d
sudo tee /etc/vault.d/vault.hcl <<EOF
exit_after_auth = false
pid_file = "./pidfile"

auto_auth {
  method "aws" {
    mount_path = "auth/aws"
    config = {
      type = "iam"
      role = "${app_role}"
    }
  }

  sink "file" {
    config = {
      #path = "/home/ubuntu/vault-token-via-agent"
      path = "./vault-token"
      mode = 644
    }
  }
}

vault {
  address = "https://${vault_addr}:8200"
  tls_skip_verify = true
  retry {
    num_retries = 5
  }
}

cache {
  use_auto_auth_token = true
}

listener "tcp" {
  address = "127.0.0.1:8100"
  tls_disable = true
}
EOF
sudo chmod -R 0644 /etc/vault.d/vault.hcl

# SYSTEMD VAULT-AGENT
sudo tee -a /etc/systemd/system/vault.service <<EOF
[Unit]
Description=Vault Agent
Documentation=https://www.vaultproject.io/docs/
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=/etc/vault.d/vault.hcl

[Service]
WorkingDirectory=/etc/vault.d
#ProtectSystem=full
ProtectHome=read-only
#PrivateTmp=yes
#PrivateDevices=yes
#NoNewPrivileges=yes

Restart=on-failure
PermissionsStartOnly=true
ExecStart=/usr/local/bin/vault agent -config=/etc/vault.d/vault.hcl -log-level=debug
ExecReload=/bin/kill -HUP
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
EOF
sudo chmod 644 /etc/systemd/system/vault.service

# SERVICE VAULT AGENT START
sudo systemctl daemon-reload
sudo systemctl start vault.service
sudo systemctl enable vault.service
sleep 60
export VAULT_AGENT_ADDR="http://127.0.0.1:8100"

##--------------------------------------------------------------------
# AWS CREDENTIALS CONFIGURATION
mkdir /home/ubuntu/.aws
sudo tee -a /home/ubuntu/.aws/credentials <<EOF
[testing]
aws_access_key_id = ${access_key}
aws_secret_access_key = ${secret_key}
EOF
sudo chmod 644 /home/ubuntu/.aws/credentials
sudo chown ubuntu:ubuntu /home/ubuntu/.aws/credentials

##--------------------------------------------------------------------
# REPO SERVER CONFIGURATION
sudo mkdir -pm 0755 /etc/${service}.d/config
sudo tee -a /etc/${service}.d/config/repos.yaml <<EOF
repos:
  - id: /.*/
    allowed_overrides: [apply_requirements, workflow, delete_source_branch_on_merge]
    allow_custom_workflows: true
workflows:
  ${environment}:
    plan:
      steps:
        - env:
            name: ENV_NAME
            value: ${environment}
        - env:
            name: ENV_REGION
            value: ${aws_region}
        - env:
            name: BUCKET_NAME
            value: ${bucket_name}
        - env:
            name: DYNAMO_NAME
            value: ${dynamo_name}
        - run: echo PLANNING && rm -rf .terraform
        - run: terraform init -backend-config="region=\$ENV_REGION" -backend-config="bucket=\$BUCKET_NAME" -backend-config="dynamodb_table=\$DYNAMO_NAME" -backend-config="key=\$BASE_REPO_NAME/\$BASE_BRANCH_NAME/\$PROJECT_NAME.tfstate"
        - plan:
            extra_args: [ -var-file=\$ENV_NAME.tfvars ]
    apply:
      steps:
        - run: echo APPLYING
        - apply
EOF

##--------------------------------------------------------------------
# CONTAINER SERVICE
# RUNATLANTIS Docker Hub: https://github.com/runatlantis/atlantis/pkgs/container/atlantis
# RUNATLANTIS Actual last version: docker pull ghcr.io/runatlantis/atlantis:v0.19.8-pre.20220722
sudo tee -a /etc/systemd/system/${service}.service <<EOF
[Unit]
Description=${service}-server as a service
Requires=docker.service
After=docker.service

[Service]
Restart=on-failure
RestartSec=10
ExecStart=/usr/bin/docker run --name %p --rm --privileged -p 4141:4141 -v /mnt/nfs/${entity}/services/${service}/data:/home/${service}/.${service} -v /etc/${service}.d/config:/home/${service}/config -v /home/ubuntu/.aws/credentials:/home/${service}/.aws/credentials -v /etc/vault.d/vault-token:/home/${service}/.vault-token:rw ${registry}${container_version} server --gh-user="${git_user}" --gh-token="${git_token}" --gh-webhook-secret="${git_webhook_secret}" --repo-allowlist="*" --repo-config=/home/${service}/config/repos.yaml
ExecStop=-/usr/bin/docker stop -t 2 %p

[Install]
WantedBy=multi-user.target
EOF
sudo chmod 644 /etc/systemd/system/${service}.service

# SERVICE START
sudo systemctl daemon-reload
sudo systemctl start ${service}.service
sudo systemctl enable ${service}.service
sleep 120

# SET PERMISSIONS TO VAULT TOKEN IN CONTAINER
docker exec ${service} chmod 644 /home/${service}/.vault-token

##--------------------------------------------------------------------
# IMPORTANT!