#!/usr/bin/env bash
set -Eeuo pipefail
export AWS_PAGER=""

# ---------- Config (override via env) ----------
PREFIX="${PREFIX:-ethnus-mocktest-01}"
REGION="${REGION:-us-east-1}"
TF_DIR="${TF_DIR:-$(pwd)}"   # folder containing your terraform (main.tf etc.)
BUCKET_HINT_SUFFIX="${BUCKET_HINT_SUFFIX:--data}"  # bucket ends with this
KMS_ALIAS="alias/${PREFIX}-cmk"

# ---------- Helpers ----------
info(){ printf " [..] %s\n" "$*"; }
ok(){   printf " [OK] %s\n" "$*"; }
warn(){ printf " [SKIP] %s\n" "$*"; }
uniq_nonempty(){ tr '\t' '\n' | sed '/^$/d' | sort -u; }

aws configure set region "$REGION" >/dev/null 2>&1 || true
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo unknown)"
info "cleanup start | acct=$ACCOUNT_ID region=$REGION prefix=$PREFIX"

# ---------- 0) Terraform destroy (optional, bounded) ----------
if [ -f "${TF_DIR}/main.tf" ]; then
  info "terraform destroy in ${TF_DIR}"
  ( cd "$TF_DIR" && terraform destroy -no-color -compact-warnings -auto-approve -var "region=${REGION}" -var "prefix=${PREFIX}" ) || warn "terraform destroy returned non-zero (continuing)"
else
  warn "terraform main.tf not found under ${TF_DIR} (skipping TF destroy)"
fi

# ---------- 1) S3: hard purge versioned bucket then delete ----------
info "discover bucket"
BUCKET="$(aws s3api list-buckets --query "Buckets[?starts_with(Name, '${PREFIX}-${ACCOUNT_ID}-') && ends_with(Name, '${BUCKET_HINT_SUFFIX}')].Name|[0]" --output text 2>/dev/null || echo None)"
if [ "${BUCKET:-None}" != "None" ] && [ "${BUCKET}" != "None" ]; then
  info "empty bucket (versions & delete markers): ${BUCKET}"

  # delete object versions
  aws s3api list-object-versions --bucket "$BUCKET" --output json \
  | jq -r '.Versions // [] | .[] | [.Key, .VersionId] | @tsv' \
  | while IFS=$'\t' read -r k v; do
      [ -n "${v:-}" ] && aws s3api delete-object --bucket "$BUCKET" --key "$k" --version-id "$v" >/dev/null 2>&1 || true
    done

  # delete delete-markers
  aws s3api list-object-versions --bucket "$BUCKET" --output json \
  | jq -r '.DeleteMarkers // [] | .[] | [.Key, .VersionId] | @tsv' \
  | while IFS=$'\t' read -r k v; do
      [ -n "${v:-}" ] && aws s3api delete-object --bucket "$BUCKET" --key "$k" --version-id "$v" >/dev/null 2>&1 || true
    done

  # final sweep and delete
  aws s3 rm "s3://${BUCKET}" --recursive >/dev/null 2>&1 || true
  aws s3api delete-bucket --bucket "$BUCKET" >/dev/null 2>&1 || warn "bucket delete skipped (still in use)"
  ok "bucket processed"
else
  warn "bucket not found"
fi

# ---------- 2) Discover VPCs & related ----------
info "discover VPCs by tag"
mapfile -t VPCS < <(aws ec2 describe-vpcs --filters Name=tag:Challenge,Values="$PREFIX" --query 'Vpcs[].VpcId' --output text 2>/dev/null | uniq_nonempty)
printf " - vpcs: %s\n" "${VPCS[*]:-<none>}"

# ---------- 3) Per VPC teardown (endpoints -> waits -> RTBs -> SGs -> subnets -> VPC) ----------
for VPC in "${VPCS[@]:-}"; do
  [ -n "${VPC:-}" ] || continue

  info "vpc $VPC: delete Interface endpoints"
  mapfile -t IF_IDS < <(aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values="$VPC" Name=vpc-endpoint-type,Values=Interface --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null | uniq_nonempty)
  if [ "${#IF_IDS[@]}" -gt 0 ]; then
    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "${IF_IDS[@]}" >/dev/null 2>&1 || true
    # bounded ENI wait (max 180s)
    end=$((SECONDS+180))
    while :; do
      left="$(aws ec2 describe-network-interfaces --filters Name=vpc-id,Values="$VPC" Name=description,Values="VPC Endpoint Interface *" --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo 0)"
      [ "$left" = "0" ] && break
      [ $SECONDS -ge $end ] && { warn "vpc $VPC: ENI wait timed out ($left left)"; break; }
      sleep 5
    done
  else
    warn "vpc $VPC: no Interface endpoints"
  fi

  info "vpc $VPC: delete Gateway endpoints"
  mapfile -t GW_IDS < <(aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values="$VPC" Name=vpc-endpoint-type,Values=Gateway --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null | uniq_nonempty)
  [ "${#GW_IDS[@]}" -gt 0 ] && aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "${GW_IDS[@]}" >/dev/null 2>&1 || warn "vpc $VPC: no Gateway endpoints"

  info "vpc $VPC: strip peering routes"
  mapfile -t RTBS_ALL < <(aws ec2 describe-route-tables --filters Name=vpc-id,Values="$VPC" --query 'RouteTables[].RouteTableId' --output text 2>/dev/null | uniq_nonempty)
  for rtb in "${RTBS_ALL[@]:-}"; do
    [ -n "${rtb:-}" ] || continue
    mapfile -t PCX_DESTS < <(aws ec2 describe-route-tables --route-table-ids "$rtb" --query 'RouteTables[0].Routes[] | [?VpcPeeringConnectionId!=null].DestinationCidrBlock' --output text 2>/dev/null | uniq_nonempty)
    for dest in "${PCX_DESTS[@]:-}"; do
      [ -n "${dest:-}" ] && aws ec2 delete-route --route-table-id "$rtb" --destination-cidr-block "$dest" >/dev/null 2>&1 || true
    done
  done

  info "vpc $VPC: delete non-main RTBs"
  mapfile -t RTBS < <(aws ec2 describe-route-tables --filters Name=vpc-id,Values="$VPC" --query 'RouteTables[].{Id:RouteTableId,Main:length(Associations[?Main==`true`])}' --output json 2>/dev/null | jq -r '.[] | select(.Main==0) | .Id' | uniq_nonempty)
  for rtb in "${RTBS[@]:-}"; do
    [ -n "${rtb:-}" ] || continue
    mapfile -t DESTS < <(aws ec2 describe-route-tables --route-table-ids "$rtb" --query 'RouteTables[0].Routes[].DestinationCidrBlock' --output text 2>/dev/null | uniq_nonempty)
    for dest in "${DESTS[@]:-}"; do
      [ "$dest" = "local" ] && continue
      aws ec2 delete-route --route-table-id "$rtb" --destination-cidr-block "$dest" >/dev/null 2>&1 || true
    done
    aws ec2 delete-route-table --route-table-id "$rtb" >/dev/null 2>&1 || warn "rtb $rtb in use"
  done

  info "vpc $VPC: delete our SGs (vpce/lambda) if present"
  for NAME in "${PREFIX}-vpce-sg" "${PREFIX}-lambda-sg"; do
    SGID="$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC" Name=group-name,Values="$NAME" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)"
    [ "$SGID" = "None" ] && continue
    aws ec2 revoke-security-group-egress --group-id "$SGID" --protocol -1 --port -1 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
    aws ec2 delete-security-group --group-id "$SGID" >/dev/null 2>&1 || warn "sg $SGID still in use"
  done

  info "vpc $VPC: delete subnets"
  mapfile -t SUBS < <(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" --query 'Subnets[].SubnetId' --output text 2>/dev/null | uniq_nonempty)
  for sn in "${SUBS[@]:-}"; do
    [ -n "${sn:-}" ] && aws ec2 delete-subnet --subnet-id "$sn" >/dev/null 2>&1 || warn "subnet $sn in use"
  done

  info "vpc $VPC: delete VPC"
  aws ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1 || warn "vpc $VPC still in use"
done

# ---------- 4) Delete peering connections by tag ----------
mapfile -t PCXS < <(aws ec2 describe-vpc-peering-connections --filters Name=tag:Challenge,Values="$PREFIX" --query 'VpcPeeringConnections[].VpcPeeringConnectionId' --output text 2>/dev/null | uniq_nonempty)
for pcx in "${PCXS[@]:-}"; do
  [ -n "${pcx:-}" ] && aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$pcx" >/dev/null 2>&1 || true
done

# ---------- 5) Lambda log groups ----------
for LG in "/aws/lambda/${PREFIX}-writer" "/aws/lambda/${PREFIX}-reader"; do
  aws logs delete-log-group --log-group-name "$LG" >/dev/null 2>&1 || true
done

# ---------- 6) KMS alias + schedule key deletion ----------
KEY_ID="$(aws kms list-aliases --query "Aliases[?AliasName=='${KMS_ALIAS}'].TargetKeyId|[0]" --output text 2>/dev/null || echo None)"
[ "$KEY_ID" != "None" ] && aws kms schedule-key-deletion --key-id "$KEY_ID" --pending-window-in-days 7 >/dev/null 2>&1 || true
aws kms delete-alias --alias-name "$KMS_ALIAS" >/dev/null 2>&1 || true

ok "cleanup complete"
