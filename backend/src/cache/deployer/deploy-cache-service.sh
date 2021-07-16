#!/bin/bash
#
# Copyright 2020 The Kubeflow Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This script is for deploying cache service to an existing cluster.
# Prerequisite: config kubectl to talk to your cluster. See ref below:
# https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl

set -ex
# Warning: grep in this image does not support long option names like --word-regexp

echo "Start deploying cache service to existing cluster:"

NAMESPACE=${NAMESPACE_TO_WATCH:-kubeflow}
MUTATING_WEBHOOK_CONFIGURATION_NAME="cache-webhook-${NAMESPACE}"
WEBHOOK_SECRET_NAME=webhook-server-tls

# Getting correct kubectl. Kubernetes only supports kubectl versions within +/-1 minor version.
# kubectl has some resource version information hardcoded, so using too old kubectl can lead to errors
mkdir -p "$HOME/bin"
export PATH="$HOME/bin:$PATH"
{
    server_version_major_minor=$(kubectl version --output json | jq --raw-output '(.serverVersion.major + "." + .serverVersion.minor)' | tr -d '"+')
    stable_build_version=$(curl -s "https://storage.googleapis.com/kubernetes-release/release/stable-${server_version_major_minor}.txt")
    kubectl_url="https://storage.googleapis.com/kubernetes-release/release/${stable_build_version}/bin/linux/amd64/kubectl"
    curl -L -o "$HOME/bin/kubectl" "$kubectl_url"
    chmod +x "$HOME/bin/kubectl"
} || true

# This should fail if there are connectivity problems
# Gotcha: Listing all objects requires list permission,
# but when listing a single oblect kubectl will fail if it's not found
# unless --ignore-not-found is specified.
kubectl get mutatingwebhookconfigurations "${MUTATING_WEBHOOK_CONFIGURATION_NAME}" --namespace "${NAMESPACE}" --ignore-not-found >$HOME/webhooks.txt
kubectl get secrets "${WEBHOOK_SECRET_NAME}" --namespace "${NAMESPACE}" --ignore-not-found >$HOME/cache_secret.txt

webhook_config_exists=false
if grep "${MUTATING_WEBHOOK_CONFIGURATION_NAME}" -w <$HOME/webhooks.txt; then
    webhook_config_exists=true
fi

webhook_secret_exists=false
if grep "${WEBHOOK_SECRET_NAME}" -w <$HOME/cache_secret.txt; then
    webhook_secret_exists=true
fi

if [ "$webhook_config_exists" == "true" ] && [ "$webhook_secret_exists" == "true" ]; then
    echo "Webhook config and secret are already installed. Sleeping forever."
    sleep infinity
fi

if [ "$webhook_config_exists" == "true" ]; then
    echo "Warning: Webhook config exists, but the secret does not exist. Reinstalling."
    kubectl delete mutatingwebhookconfigurations "${MUTATING_WEBHOOK_CONFIGURATION_NAME}" --namespace "${NAMESPACE}"
fi

if [ "$webhook_secret_exists" == "true" ]; then
    echo "Warning: Webhook secret exists, but the config does not exist. Reinstalling."
    kubectl delete secrets "${WEBHOOK_SECRET_NAME}" --namespace "${NAMESPACE}"
fi


export CA_FILE="ca_cert"
rm -f $HOME/${CA_FILE}
touch $HOME/${CA_FILE}

# Generate signed certificate for cache server.
./webhook-create-signed-cert.sh --namespace "${NAMESPACE}" --cert_output_path "$HOME/${CA_FILE}" --secret "${WEBHOOK_SECRET_NAME}"
echo "Signed certificate generated for cache server"

cache_webhook_config_template="cache-webhook-config.v1.yaml.template"
NAMESPACE="$NAMESPACE" ./webhook-patch-ca-bundle.sh --cert_input_path "$HOME/${CA_FILE}" <./"$cache_webhook_config_template" >$HOME/cache-configmap-ca-bundle.yaml
echo "CA_BUNDLE patched successfully"

# Create MutatingWebhookConfiguration
cat $HOME/cache-configmap-ca-bundle.yaml
kubectl apply -f $HOME/cache-configmap-ca-bundle.yaml --namespace "${NAMESPACE}"

# TODO: Check whether we really need to check for the existence of the webhook
# Usually the Kubernetes objects appear immediately.
while true; do
    # Should fail if there are connectivity problems
    kubectl get mutatingwebhookconfigurations "${MUTATING_WEBHOOK_CONFIGURATION_NAME}" --namespace "${NAMESPACE}" --ignore-not-found >$HOME/webhooks.txt

    if grep "${MUTATING_WEBHOOK_CONFIGURATION_NAME}" -w <$HOME/webhooks.txt; then
        echo "Webhook has been installed. Sleeping forever."
        sleep infinity
    else
        echo "Webhook is not visible yet. Waiting a bit."
        sleep 10s
    fi
done
