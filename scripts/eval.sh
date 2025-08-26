#!/usr/bin/env bash
# User-facing evaluator (neutral) with table output
# Usage: PREFIX=ethnus-mocktest-01 REGION=us-east-1 bash eval.sh
set -uo pipefail
export AWS_PAGER=""

PREFIX="${PREFIX:-ethnus-mocktest-01}"
REGION="${REGION:-us-east-1}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required. Install jq and rerun." >&2
  exit 2
fi

aws configure set region "$REGION" >/dev/null 2>&1 || true
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")"
PARTITION="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null | awk -F: '{print $2}')"

rows=()
add_row(){ rows+=("$1|$2|$3|$4"); }

# Check if basic infrastructure exists before evaluation
check_infrastructure() {
  local bucket_count s3_vpc_endpoint ddb_table lambda_count
  
  bucket_count=$(aws s3api list-buckets --query "length(Buckets[?starts_with(Name, '${PREFIX}-') && contains(Name, 'data')])" --output text 2>/dev/null || echo "0")
  ddb_table=$(aws dynamodb describe-table --table-name "${PREFIX}-orders" --query "Table.TableName" --output text 2>/dev/null || echo "")
  lambda_count=$(aws lambda list-functions --query "length(Functions[?starts_with(FunctionName, '${PREFIX}-')])" --output text 2>/dev/null || echo "0")
  
  if [ "$bucket_count" = "0" ] || [ -z "$ddb_table" ] || [ "$lambda_count" -lt "2" ]; then
    echo ""
    echo "❌ ERROR: Infrastructure not found"
    echo ""
    echo "Expected environment components are missing."
    echo "Please deploy the infrastructure first using:"
    echo "  bash deploy.sh"
    echo ""
    echo "If deployment failed, try cleanup and redeploy:"
    echo "  bash teardown.sh && bash deploy.sh"
    echo ""
    exit 1
  fi
}

# Add infrastructure check before evaluation
check_infrastructure

s3_bucket_by_prefix() {
  aws s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null \
    | tr '\t' '\n' | grep -E "^${PREFIX}-${ACCOUNT_ID}-[0-9]+-data$" | head -n1 || true
}
vpc_by_cidr_and_tag() {
  local cidr="$1"
  aws ec2 describe-vpcs --filters "Name=tag:Challenge,Values=${PREFIX}" \
    --query 'Vpcs[].[VpcId,CidrBlock]' --output text 2>/dev/null \
    | awk -v C="$cidr" '$2==C{print $1; exit}'
}

BUCKET="$(s3_bucket_by_prefix)"
DDB_TABLE="${PREFIX}-orders"
WRITER="${PREFIX}-writer"
READER="${PREFIX}-reader"
TOPIC_ARN="$(aws sns list-topics --query "Topics[?contains(TopicArn, ':${PREFIX}-topic')].TopicArn|[0]" --output text 2>/dev/null || echo "None")"

VPC_A_ID="$(vpc_by_cidr_and_tag 10.10.0.0/16)"
RTA_MAIN="$(aws ec2 describe-route-tables --filters Name=vpc-id,Values="$VPC_A_ID" Name=association.main,Values=true --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || echo None)"

VPCE_JSON="$(aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values="$VPC_A_ID" --output json 2>/dev/null || echo '{}')"
VPCE_S3_ID="$(echo "$VPCE_JSON" | jq -r '.VpcEndpoints[]? | select(.ServiceName|endswith(".s3")) | .VpcEndpointId' | head -n1)"
VPCE_DDB_ID="$(echo "$VPCE_JSON" | jq -r '.VpcEndpoints[]? | select(.ServiceName|endswith(".dynamodb")) | .VpcEndpointId' | head -n1)"
VPCE_EXEC_ID="$(echo "$VPCE_JSON" | jq -r '.VpcEndpoints[]? | select(.ServiceName|endswith(".execute-api")) | .VpcEndpointId' | head -n1)"

API_ID="$(aws apigateway get-rest-apis --query "items[?name=='${PREFIX}-api'].id|[0]" --output text 2>/dev/null || echo None)"
API_JSON="{}"; API_RESOURCES_JSON="{}"; POLICY_JSON=""
if [ "$API_ID" != "None" ]; then
  API_JSON="$(aws apigateway get-rest-api --rest-api-id "$API_ID" --output json 2>/dev/null || echo '{}')"
  # FIXED: parse .policy directly with fromjson, compact (-c), and tolerate empty
  POLICY_JSON="$(echo "$API_JSON" | jq -c '(.policy // empty) | select(.!="") | fromjson' 2>/dev/null || echo "")"
  API_RESOURCES_JSON="$(aws apigateway get-resources --rest-api-id "$API_ID" --output json 2>/dev/null || echo '{}')"
fi

echo "evaluation"
printf " account : %s\n" "$ACCOUNT_ID"
printf " region  : %s\n" "$REGION"
printf " prefix  : %s\n" "$PREFIX"
rule 72
printf "| %s | %s | %s | %s |\n" "$(pad "#" 2)" "$(pad "Check" 28)" "$(pad "Status" 11)" "$(pad "Note" 23)"
rule 72

ACCEPTED=0; INCOMPLETE=0; i=1

# ---------- Challenge 1: Resource labeling compliance ----------
BUCKET_NAME="$(aws s3api list-buckets --query "Buckets[?starts_with(Name, '${PREFIX}-') && contains(Name, 'data')].Name|[0]" --output text 2>/dev/null || echo "")"
if [ -n "$BUCKET_NAME" ]; then
  BUCKET_TAGS="$(aws s3api get-bucket-tagging --bucket "$BUCKET_NAME" --query 'TagSet[?Key==`Owner` && Value==`Ethnus`]|[0].Key' --output text 2>/dev/null || echo "")"
  if [ "$BUCKET_TAGS" = "Owner" ]; then
    add_row "1" "Resource governance: storage" "ACCEPTED" "• Governance standards met"
  else
    add_row "1" "Resource governance: storage" "INCOMPLETE" "• Review organizational standards"
  fi
else
  add_row "1" "Resource governance: storage" "INCOMPLETE" "• Infrastructure not found"
fi

# ---------- Challenge 2: Database resource compliance ----------
DDB_TAGS="$(aws dynamodb list-tags-of-resource --resource-arn "arn:${PARTITION}:dynamodb:${REGION}:${ACCOUNT_ID}:table/${PREFIX}-orders" --query 'Tags[?Key==`Owner` && Value==`Ethnus`]|[0].Key' --output text 2>/dev/null || echo "")"
if [ "$DDB_TAGS" = "Owner" ]; then
  add_row "2" "Resource governance: database" "ACCEPTED" "• Governance standards met"
else
  add_row "2" "Resource governance: database" "INCOMPLETE" "• Review organizational standards"
fi

# ---------- Challenge 3: Compute resource limits ----------
WRITER_CONCURRENCY="$(aws lambda get-function-concurrency --function-name "${PREFIX}-writer" --query 'ReservedConcurrencyLimit' --output text 2>/dev/null || echo "None")"
if [ "$WRITER_CONCURRENCY" = "None" ]; then
  add_row "3" "Performance optimization: compute" "ACCEPTED" "• Resource allocation optimized"
else
  add_row "3" "Performance optimization: compute" "INCOMPLETE" "• Review performance settings"
fi

# ---------- Challenge 4: Application configuration ----------
WRITER_ENV="$(aws lambda get-function-configuration --function-name "${PREFIX}-writer" --query 'Environment.Variables.DDB_TABLE' --output text 2>/dev/null || echo "")"
if [ "$WRITER_ENV" = "${PREFIX}-orders" ]; then
  add_row "4" "Application configuration: runtime" "ACCEPTED" "• Configuration aligned"
else
  add_row "4" "Application configuration: runtime" "INCOMPLETE" "• Review runtime parameters"
fi

# ---------- Challenge 5: Messaging service access ----------
TOPIC_ARN="$(aws sns list-topics --query "Topics[?contains(Arn, '${PREFIX}-notifications')].Arn|[0]" --output text 2>/dev/null || echo "")"
if [ -n "$TOPIC_ARN" ]; then
  TEST_PUBLISH="$(aws sns publish --topic-arn "$TOPIC_ARN" --message "test" --query 'MessageId' --output text 2>/dev/null || echo "error")"
  if [ "$TEST_PUBLISH" != "error" ]; then
    add_row "5" "Communication services: publish" "ACCEPTED" "• Message delivery enabled"
  else
    add_row "5" "Communication services: publish" "INCOMPLETE" "• Review access policies"
  fi
else
  add_row "5" "Communication services: publish" "INCOMPLETE" "• Service not available"
fi

# ---------- Challenge 6: Network service policies ----------
DDB_VPC_ENDPOINT="$(aws ec2 describe-vpc-endpoints --filters "Name=service-name,Values=com.amazonaws.${REGION}.dynamodb" "Name=tag:Name,Values=${PREFIX}-ddb-endpoint" --query 'VpcEndpoints[0].VpcEndpointId' --output text 2>/dev/null || echo "")"
if [ -n "$DDB_VPC_ENDPOINT" ] && [ "$DDB_VPC_ENDPOINT" != "None" ]; then
  ENDPOINT_POLICY="$(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$DDB_VPC_ENDPOINT" --query 'VpcEndpoints[0].PolicyDocument' --output text 2>/dev/null || echo "")"
  if echo "$ENDPOINT_POLICY" | jq -e '.Statement[]|select(.Action[]?=="dynamodb:PutItem")' >/dev/null 2>&1; then
    add_row "6" "Network security: data access" "ACCEPTED" "• Access controls configured"
  else
    add_row "6" "Network security: data access" "INCOMPLETE" "• Review access permissions"
  fi
else
  add_row "6" "Network security: data access" "INCOMPLETE" "• Endpoint configuration needed"
fi

# ---------- Challenge 7: Network routing configuration ----------
MAIN_RT_ID="$(aws ec2 describe-route-tables --filters "Name=tag:Name,Values=${PREFIX}-main-rt" --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || echo "")"
if [ -n "$MAIN_RT_ID" ] && [ "$MAIN_RT_ID" != "None" ]; then
  S3_ROUTE_COUNT="$(aws ec2 describe-route-tables --route-table-ids "$MAIN_RT_ID" --query 'length(RouteTables[0].Routes[?GatewayId && starts_with(GatewayId, `vpce-`) && DestinationPrefixListId])' --output text 2>/dev/null || echo "0")"
  if [ "$S3_ROUTE_COUNT" -gt "1" ]; then
    add_row "7" "Network routing: service access" "ACCEPTED" "• Traffic routing optimized"
  else
    add_row "7" "Network routing: service access" "INCOMPLETE" "• Review routing configuration"
  fi
else
  add_row "7" "Network routing: service access" "INCOMPLETE" "• Routing infrastructure needed"
fi

# ---------- Challenge 8: API service integration ----------
API_ID="$(aws apigateway get-rest-apis --query "items[?name=='${PREFIX}-api'].id|[0]" --output text 2>/dev/null || echo "")"
if [ -n "$API_ID" ] && [ "$API_ID" != "None" ]; then
  ORDERS_RESOURCE="$(aws apigateway get-resources --rest-api-id "$API_ID" --query "items[?pathPart=='orders'].id|[0]" --output text 2>/dev/null || echo "")"
  if [ -n "$ORDERS_RESOURCE" ] && [ "$ORDERS_RESOURCE" != "None" ]; then
    INTEGRATION_URI="$(aws apigateway get-integration --rest-api-id "$API_ID" --resource-id "$ORDERS_RESOURCE" --http-method GET --query 'uri' --output text 2>/dev/null | grep "${PREFIX}-reader" || echo "")"
    if [ -n "$INTEGRATION_URI" ]; then
      add_row "8" "API service: backend integration" "ACCEPTED" "• Service integration complete"
    else
      add_row "8" "API service: backend integration" "INCOMPLETE" "• Review service connections"
    fi
  else
    add_row "8" "API service: backend integration" "INCOMPLETE" "• Resource configuration needed"
  fi
else
  add_row "8" "API service: backend integration" "INCOMPLETE" "• API infrastructure needed"
fi

# ---------- Challenge 9: API access controls ----------
if [ -n "$API_ID" ] && [ "$API_ID" != "None" ]; then
  API_JSON="$(aws apigateway get-rest-api --rest-api-id "$API_ID" 2>/dev/null || echo "")"
  POLICY_JSON="$(echo "$API_JSON" | jq -c '(.policy // empty) | select(.!="") | fromjson' 2>/dev/null || echo "")"
  if [ -n "$POLICY_JSON" ]; then
    VPC_CONDITION="$(echo "$POLICY_JSON" | jq -e '.Statement[]|select(.Condition.StringEquals?"aws:SourceVpce")' 2>/dev/null || echo "")"
    if [ -n "$VPC_CONDITION" ]; then
      add_row "9" "API security: access restrictions" "ACCEPTED" "• Access controls enforced"
    else
      add_row "9" "API security: access restrictions" "INCOMPLETE" "• Review access policies"
    fi
  else
    add_row "9" "API security: access restrictions" "INCOMPLETE" "• Policy configuration needed"
  fi
else
  add_row "9" "API security: access restrictions" "INCOMPLETE" "• API infrastructure needed"
fi

# ---------- Challenge 10: Automation scheduling ----------
RULE_STATE="$(aws events describe-rule --name "${PREFIX}-tick" --query 'State' --output text 2>/dev/null || echo "")"
if [ "$RULE_STATE" = "ENABLED" ]; then
  add_row "10" "Process automation: scheduling" "ACCEPTED" "• Automation workflows active"
else
  add_row "10" "Process automation: scheduling" "INCOMPLETE" "• Review automation settings"
fi

# ---------- Challenge 11: System integration testing ----------
WRITER_TEST="$(aws lambda invoke --function-name "${PREFIX}-writer" --payload '{}' /tmp/writer-response.json >/dev/null 2>&1 && cat /tmp/writer-response.json 2>/dev/null || echo '{}')"
WRITER_SUCCESS="$(echo "$WRITER_TEST" | jq -r '.ddb_ok and .s3_ok and .sns_ok' 2>/dev/null || echo "false")"
rm -f /tmp/writer-response.json 2>/dev/null
if [ "$WRITER_SUCCESS" = "true" ]; then
  add_row "11" "System integration: end-to-end" "ACCEPTED" "• All services operational"
else
  add_row "11" "System integration: end-to-end" "INCOMPLETE" "• Review system dependencies"
fi

# ---------- Challenge 12: Service delivery verification ----------
if [ -n "$API_ID" ] && [ "$API_ID" != "None" ]; then
  API_ENDPOINT="https://${API_ID}.execute-api.${REGION}.amazonaws.com/prod/orders"
  VPC_A_ID="$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${PREFIX}-vpc-a" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "")"
  if [ -n "$VPC_A_ID" ] && [ "$VPC_A_ID" != "None" ]; then
    API_VPC_ENDPOINT="$(aws ec2 describe-vpc-endpoints --filters "Name=service-name,Values=com.amazonaws.${REGION}.execute-api" "Name=vpc-id,Values=${VPC_A_ID}" --query 'VpcEndpoints[0].DnsEntries[0].DnsName' --output text 2>/dev/null || echo "")"
    if [ -n "$API_VPC_ENDPOINT" ] && [ "$API_VPC_ENDPOINT" != "None" ]; then
      FLAG_TEST="$(curl -s -m 10 "https://${API_VPC_ENDPOINT}/prod/orders" -H "Host: ${API_ID}.execute-api.${REGION}.amazonaws.com" 2>/dev/null | jq -r '.flag // empty' 2>/dev/null || echo "")"
      if [[ "$FLAG_TEST" =~ ^ETHNUS\{ ]]; then
        add_row "12" "Service delivery: final verification" "ACCEPTED" "• Mission accomplished"
      else
        add_row "12" "Service delivery: final verification" "INCOMPLETE" "• Complete all prerequisites"
      fi
    else
      add_row "12" "Service delivery: final verification" "INCOMPLETE" "• Network access required"
    fi
  else
    add_row "12" "Service delivery: final verification" "INCOMPLETE" "• Infrastructure prerequisites"
  fi
else
  add_row "12" "Service delivery: final verification" "INCOMPLETE" "• Service not available"
fi

for r in "${rows[@]}"; do IFS="|" read -r c1 c2 c3 c4 <<<"$r"; printf "| %s | %s | %s | %s |\n" "$(pad "$c1" 2)" "$(pad "$c2" 28)" "$(pad "$c3" 11)" "$(pad "$c4" 23)"; done
rule 72
printf "ACCEPTED : %s\n" "$ACCEPTED"
printf "INCOMPLETE : %s\n" "$INCOMPLETE"
[ "$INCOMPLETE" -eq 0 ]
