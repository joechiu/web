#!/bin/bash

RG=rg-delme-australiaeast-iac-001
WS=ops-ws-5608
SUBID=815f7fcd-2bf5-4083-8da4-41747b02e57f
ENDPOINT=onecx-tool4-api
NEW_DEPLOYMENT=red

ENVIRONMENT=ok5-tool1-flow
ENVIRONMENT_YAML=$NEW_DEPLOYMENT-onecx-deployment.yml
INSTANCE=Standard_DS2_v2

echo "3.0. create new $NEW_DEPLOYMENT deployment"
cat > "$ENVIRONMENT_YAML" <<EOF
\$schema: https://azuremlschemas.azureedge.net/latest/managedOnlineDeployment.schema.json
name: $NEW_DEPLOYMENT
endpoint_name: $ENDPOINT
model:
  path: .

environment:
  azureml:$ENVIRONMENT@latest

# instance_type: Standard_B2ms
instance_type: $INSTANCE

instance_count: 1
request_settings:
  request_timeout_ms: 180000
  max_concurrent_requests_per_instance: 1

environment_variables:
  PRT_CONFIG_OVERRIDE: deployment.subscription_id=$SUBID,deployment.resource_group=$RG,deployment.workspace_name=$WS

EOF
echo "3.1. run creating command"
az ml online-deployment update \
  --file $ENVIRONMENT_YAML

sleep 10
echo "3.2. wait until it is healthy - Failed / Succeeded"
az ml online-deployment show \
  --name $NEW_DEPLOYMENT \
  --endpoint $ENDPOINT \
  --query provisioning_state \
  -o tsv

echo "DONE!"
