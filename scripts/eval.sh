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
pad(){ local txt="$1" w="$2" fill; local len=${#txt}; if [ "$len" -ge "$w" ]; then echo -n "$txt"; else fill=$((w-len)); printf "%s%*s" "$txt" $fill ""; fi; }
rule(){ printf "%s\n" "$(printf '%0.s-' $(seq 1 "$1"))"; }

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
rule 86
printf "| %s | %s | %s | %s |\n" "$(pad "#" 2)" "$(pad "Check" 36)" "$(pad "Status" 10)" "$(pad "Note" 20)"
rule 86

ACCEPTED=0; INCOMPLETE=0; i=1

# 1) Tags: object storage
if [ -n "${BUCKET:-}" ] && aws s3api get-bucket-tagging --bucket "$BUCKET" >/dev/null 2>&1; then
  TAGS_JSON="$(aws s3api get-bucket-tagging --bucket "$BUCKET" --output json 2>/dev/null || echo '{}')"
  has_owner="$(echo "$TAGS_JSON" | jq -r '.TagSet[]? | select(.Key=="Owner" and .Value=="Ethnus") | .Value' | wc -l)"
  has_chal="$(echo "$TAGS_JSON" | jq -r '.TagSet[]? | select(.Key=="Challenge" and .Value=="'"$PREFIX"'") | .Value' | wc -l)"
  if [ "$has_owner" -ge 1 ] && [ "$has_chal" -ge 1 ]; then ST="ACCEPTED"; NOTE="ok"; else ST="INCOMPLETE"; NOTE="tags"; fi
else ST="INCOMPLETE"; NOTE="tags"; fi
add_row "$i" "Resource governance: storage" "$ST" "$NOTE"; [ "$ST" = "ACCEPTED" ] && ACCEPTED=$((ACCEPTED+1)) || INCOMPLETE=$((INCOMPLETE+1)); i=$((i+1))

# 2) Tags: key-value database
DDB_ARN="arn:${PARTITION:-aws}:dynamodb:${REGION}:${ACCOUNT_ID}:table/${DDB_TABLE}"
if aws dynamodb describe-table --table-name "$DDB_TABLE" >/dev/null 2>&1; then
  if TJSON="$(aws dynamodb list-tags-of-resource --resource-arn "$DDB_ARN" --output json 2>/dev/null)"; then
    has_owner="$(echo "$TJSON" | jq -r '.Tags[]? | select(.Key=="Owner" and .Value=="Ethnus") | .Value' | wc -l)"
    has_chal="$(echo "$TJSON" | jq -r '.Tags[]? | select(.Key=="Challenge" and .Value=="'"$PREFIX"'") | .Value' | wc -l)"
  else
    TJSON="$(aws resourcegroupstaggingapi get-resources --resource-type-filters dynamodb:table --tag-filters Key=Owner,Values=Ethnus Key=Challenge,Values="$PREFIX" --query 'ResourceTagMappingList[].ResourceARN' --output json 2>/dev/null || echo '[]')"
    echo "$TJSON" | jq -e --arg arn "$DDB_ARN" '.[] | select(.==$arn)' >/dev/null 2>&1 && has_owner=1 || has_owner=0
    has_chal=$has_owner
  fi
  if [ "${has_owner:-0}" -ge 1 ] && [ "${has_chal:-0}" -ge 1 ]; then ST="ACCEPTED"; NOTE="ok"; else ST="INCOMPLETE"; NOTE="tags"; fi
else ST="INCOMPLETE"; NOTE="table"; fi
add_row "$i" "Resource governance: database" "$ST" "$NOTE"; [ "$ST" = "ACCEPTED" ] && ACCEPTED=$((ACCEPTED+1)) || INCOMPLETE=$((INCOMPLETE+1)); i=$((i+1))

# 3) Compute concurrency
if aws lambda get-function --function-name "$WRITER" >/dev/null 2>&1; then
  RC="$(aws lambda get-function-concurrency --function-name "$WRITER" --query 'ReservedConcurrentExecutions' --output text 2>/dev/null || echo "UNSET")"
  if [ "$RC" = "0" ]; then ST="INCOMPLETE"; NOTE="limit"; else ST="ACCEPTED"; NOTE="ok"; fi
else ST="INCOMPLETE"; NOTE="function"; fi
add_row "$i" "Performance optimization: compute" "$ST" "$NOTE"; [ "$ST" = "ACCEPTED" ] && ACCEPTED=$((ACCEPTED+1)) || INCOMPLETE=$((INCOMPLETE+1)); i=$((i+1))

# 4) Compute configuration
if aws lambda get-function --function-name "$WRITER" >/dev/null 2>&1; then
  WT="$(aws lambda get-function-configuration --function-name "$WRITER" --query 'Environment.Variables.DDB_TABLE' --output text 2>/dev/null || echo "")"
  if [ "$WT" = "${DDB_TABLE}" ]; then ST="ACCEPTED"; NOTE="ok"; else ST="INCOMPLETE"; NOTE="env"; fi
else ST="INCOMPLETE"; NOTE="function"; fi
add_row "$i" "Application configuration: runtime" "$ST" "$NOTE"; [ "$ST" = "ACCEPTED" ] && ACCEPTED=$((ACCEPTED+1)) || INCOMPLETE=$((INCOMPLETE+1)); i=$((i+1))

# 5) Notifications publish
if [ "$TOPIC_ARN" != "None" ] && MID="$(aws sns publish --topic-arn "$TOPIC_ARN" --message '{"probe":"ok"}' --query MessageId --output text 2>/dev/null)"; then
  ST="ACCEPTED"; NOTE="ok"
else ST="INCOMPLETE"; NOTE="publish"; fi
add_row "$i" "Communication services: publish" "$ST" "$NOTE"; [ "$ST" = "ACCEPTED" ] && ACCEPTED=$((ACCEPTED+1)) || INCOMPLETE=$((INCOMPLETE+1)); i=$((i+1))

# 6) Private data endpoint policy
if [ -n "${VPCE_DDB_ID:-}" ]; then
  PJSON="$(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$VPCE_DDB_ID" --query 'VpcEndpoints[0].PolicyDocument' --output text 2>/dev/null || echo '')"
  if [ -n "$PJSON" ] && echo "$PJSON" | jq -e '.' >/dev/null 2>&1 \
     && echo "$PJSON" | jq -e '([.Statement[]? | select(.Effect=="Allow") | .Action] | flatten | map(tostring) | any(.=="dynamodb:PutItem" or .=="dynamodb:*"))' >/dev/null 2>&1; then
    ST="ACCEPTED"; NOTE="ok"
  else ST="INCOMPLETE"; NOTE="policy"; fi
else ST="INCOMPLETE"; NOTE="endpoint"; fi
add_row "$i" "Network security: data access" "$ST" "$NOTE"; [ "$ST" = "ACCEPTED" ] && ACCEPTED=$((ACCEPTED+1)) || INCOMPLETE=$((INCOMPLETE+1)); i=$((i+1))

# 7) Network endpoints routing
okmain=1
if [ -n "${VPCE_S3_ID:-}" ] && [ "$RTA_MAIN" != "None" ]; then
  RTIDS="$(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$VPCE_S3_ID" --query 'VpcEndpoints[0].RouteTableIds' --output text 2>/dev/null | tr '\t' '\n')"
  echo "$RTIDS" | grep -qx "$RTA_MAIN" || okmain=0
else okmain=0; fi
if [ -n "${VPCE_DDB_ID:-}" ] && [ "$RTA_MAIN" != "None" ]; then
  RTIDD="$(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$VPCE_DDB_ID" --query 'VpcEndpoints[0].RouteTableIds' --output text 2>/dev/null | tr '\t' '\n')"
  echo "$RTIDD" | grep -qx "$RTA_MAIN" || okmain=0
else okmain=0; fi
[ $okmain -eq 1 ] && { ST="ACCEPTED"; NOTE="ok"; } || { ST="INCOMPLETE"; NOTE="routing"; }
add_row "$i" "Network routing: service access" "$ST" "$NOTE"; [ "$ST" = "ACCEPTED" ] && ACCEPTED=$((ACCEPTED+1)) || INCOMPLETE=$((INCOMPLETE+1)); i=$((i+1))

# 8) API integration
if [ "$API_ID" != "None" ]; then
  RES_ORDERS_ID="$(echo "$API_RESOURCES_JSON" | jq -r '.items[]? | select(.path=="/orders") | .id' 2>/dev/null | head -n1)"
  if [ -n "$RES_ORDERS_ID" ]; then
    INTEG_URI="$(aws apigateway get-integration --rest-api-id "$API_ID" --resource-id "$RES_ORDERS_ID" --http-method GET --query 'uri' --output text 2>/dev/null || echo "")"
    READER_ARN="$(aws lambda get-function --function-name "$READER" --query 'Configuration.FunctionArn' --output text 2>/dev/null || echo "")"
    if [ -n "$INTEG_URI" ] && [ -n "$READER_ARN" ] && echo "$INTEG_URI" | grep -q "$READER_ARN"; then ST="ACCEPTED"; NOTE="ok"; else ST="INCOMPLETE"; NOTE="integration"; fi
  else ST="INCOMPLETE"; NOTE="resource"; fi
else ST="INCOMPLETE"; NOTE="api"; fi
add_row "$i" "API service: backend integration" "$ST" "$NOTE"; [ "$ST" = "ACCEPTED" ] && ACCEPTED=$((ACCEPTED+1)) || INCOMPLETE=$((INCOMPLETE+1)); i=$((i+1))

# 9) API network restrictions
if [ "$API_ID" != "None" ]; then
  TYPES="$(echo "$API_JSON" | jq -r '.endpointConfiguration.types[]?' 2>/dev/null)"
  priv_ok=0; match_ok=0
  echo "$TYPES" | grep -qx "PRIVATE" && priv_ok=1
  if [ -n "$VPCE_EXEC_ID" ] && [ -n "$POLICY_JSON" ]; then
    SRC="$(echo "$POLICY_JSON" | jq -r '.Statement[]? | .Condition?."StringEquals"?."aws:SourceVpce"? // empty' 2>/dev/null | head -n1)"
    [ "$SRC" = "$VPCE_EXEC_ID" ] && match_ok=1
  fi
  if [ $priv_ok -eq 1 ] && [ $match_ok -eq 1 ]; then ST="ACCEPTED"; NOTE="ok"; else ST="INCOMPLETE"; NOTE="policy"; fi
else ST="INCOMPLETE"; NOTE="api"; fi
add_row "$i" "API security: access restrictions" "$ST" "$NOTE"; [ "$ST" = "ACCEPTED" ] && ACCEPTED=$((ACCEPTED+1)) || INCOMPLETE=$((INCOMPLETE+1)); i=$((i+1))

# 10) Scheduled invocation
RULE="${PREFIX}-tick"
if aws events describe-rule --name "$RULE" >/dev/null 2>&1; then
  STT="$(aws events describe-rule --name "$RULE" --query 'State' --output text 2>/dev/null || echo "")"
  if [ "$STT" = "ENABLED" ]; then ST="ACCEPTED"; NOTE="ok"; else ST="INCOMPLETE"; NOTE="state"; fi
else ST="INCOMPLETE"; NOTE="rule"; fi
add_row "$i" "Process automation: scheduling" "$ST" "$NOTE"; [ "$ST" = "ACCEPTED" ] && ACCEPTED=$((ACCEPTED+1)) || INCOMPLETE=$((INCOMPLETE+1)); i=$((i+1))

# 11) Compute integration test
if aws lambda get-function --function-name "$WRITER" >/dev/null 2>&1; then
  OUT="$(aws lambda invoke --function-name "$WRITER" --payload '{}' --cli-binary-format raw-in-base64-out /dev/stdout 2>/dev/null || echo '{}')"
  if echo "$OUT" | jq -e '.' >/dev/null 2>&1; then
    ddb_ok="$(echo "$OUT" | jq -r '.ddb_ok // empty')"
    s3_ok="$(echo "$OUT" | jq -r '.s3_ok // empty')"
    sns_ok="$(echo "$OUT" | jq -r '.sns_ok // empty')"
    if [ "$ddb_ok" = "true" ] && [ "$s3_ok" = "true" ] && [ "$sns_ok" = "true" ]; then ST="ACCEPTED"; NOTE="ok"; else ST="INCOMPLETE"; NOTE="io"; fi
  else ST="INCOMPLETE"; NOTE="invoke"; fi
else ST="INCOMPLETE"; NOTE="function"; fi
add_row "$i" "System integration: end-to-end" "$ST" "$NOTE"; [ "$ST" = "ACCEPTED" ] && ACCEPTED=$((ACCEPTED+1)) || INCOMPLETE=$((INCOMPLETE+1)); i=$((i+1))

# 12) Final flag
FLAG_NOTE=""
if [ "$API_ID" != "None" ]; then
  RES_ORDERS_ID="$(echo "$API_RESOURCES_JSON" | jq -r '.items[]? | select(.path=="/orders") | .id' 2>/dev/null | head -n1)"
  if [ -n "$RES_ORDERS_ID" ]; then
    TRES="$(aws apigateway test-invoke-method --rest-api-id "$API_ID" --resource-id "$RES_ORDERS_ID" --http-method GET --output json 2>/dev/null || echo '{}')"
    STATUS="$(echo "$TRES" | jq -r '.status // empty' 2>/dev/null || echo '')"
    BODY="$(echo "$TRES" | jq -r '.body // empty' 2>/dev/null || echo '')"
    FLAG=""
    if [[ "$BODY" =~ ^\{ ]]; then
      FLAG="$(echo "$BODY" | jq -r '.flag // empty' 2>/dev/null || echo '')"
    fi
    if [ "$STATUS" = "200" ] && [ -n "$FLAG" ]; then ST="ACCEPTED"; FLAG_NOTE="$FLAG"; else ST="INCOMPLETE"; FLAG_NOTE=""; fi
  else ST="INCOMPLETE"; FLAG_NOTE=""; fi
else ST="INCOMPLETE"; FLAG_NOTE=""; fi
add_row "$i" "Service delivery: final verification" "$ST" "$FLAG_NOTE"; [ "$ST" = "ACCEPTED" ] && ACCEPTED=$((ACCEPTED+1)) || INCOMPLETE=$((INCOMPLETE+1)); i=$((i+1))

for r in "${rows[@]}"; do IFS="|" read -r c1 c2 c3 c4 <<<"$r"; printf "| %s | %s | %s | %s |\n" "$(pad "$c1" 2)" "$(pad "$c2" 44)" "$(pad "$c3" 12)" "$(pad "$c4" 22)"; done
rule 86
printf "ACCEPTED : %s\n" "$ACCEPTED"
printf "INCOMPLETE : %s\n" "$INCOMPLETE"
[ "$INCOMPLETE" -eq 0 ]
