#!/usr/bin/env bash
set -euo pipefail

# Validate AWS-side setup for Red Hat Cost Management / ELS metering
# Checks:
# - Bucket/prefix existence
# - CUR report definition matches expectations
# - Latest CUR object presence under s3://<bucket>/cost/
# - Cost Allocation Tags activation status
# - IAM role and trust policy (External ID), policy attachment
#
# Usage:
#   ./validate_rh_cost_mgmt.sh <BUCKET_NAME> <AWS_REGION> [ROLE_NAME] [EXTERNAL_ID]
# Example:
#   ./validate_rh_cost_mgmt.sh rh-cost-mgmt-reports-123456789012-us-east-1 us-east-1 RH_ELS_Metering_Role abcd-1234
#
# Exit non-zero if critical validations fail. Provides actionable hints.

REPORT_NAME="koku"
S3_PREFIX="cost"
EXPECTED_ROLE_NAME="${3:-RH_ELS_Metering_Role}"
EXPECTED_EXTERNAL_ID="${4:-}"
TAG_KEY_1="com_redhat_rhel"
TAG_VAL_1="7"
TAG_KEY_2="com_redhat_rhel_addon"
TAG_VAL_2="ELS"
RH_ACCOUNT_ID="589173575009"

die() { echo "Error: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <BUCKET_NAME> <AWS_REGION> [ROLE_NAME] [EXTERNAL_ID]" >&2
  exit 1
fi

BUCKET_NAME="$1"
AWS_REGION="$2"

have aws || die "aws CLI is required"
aws sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials not configured or insufficient"

failures=0
warns=0

section() { echo; echo "== $* =="; }
ok() { echo "✔ $*"; }
warn() { echo "⚠ $*"; warns=$((warns+1)); }
fail() { echo "✖ $*"; failures=$((failures+1)); }

section "S3 bucket/prefix"
if aws s3api head-bucket --bucket "$BUCKET_NAME" >/dev/null 2>&1; then
  ok "Bucket exists: s3://$BUCKET_NAME"
else
  fail "Bucket missing: s3://$BUCKET_NAME"
fi

LATEST=$(aws s3api list-objects-v2 --bucket "$BUCKET_NAME" --prefix "$S3_PREFIX/" --query 'reverse(sort_by(Contents,&LastModified))[:1][0].{Key:Key,Time:LastModified}' --output json 2>/dev/null || echo "null")
if [[ "$LATEST" != "null" && "$LATEST" != "[]" && -n "$LATEST" ]]; then
  ok "Found CUR object under s3://$BUCKET_NAME/$S3_PREFIX/: $LATEST"
else
  warn "No CUR object found yet under s3://$BUCKET_NAME/$S3_PREFIX/. It can take up to 24h after enabling CUR."
fi

section "CUR report definition (us-east-1 API)"
CUR_CNT=$(aws cur describe-report-definitions --region us-east-1 --query "ReportDefinitions[?ReportName=='$REPORT_NAME'] | length(@)" --output text 2>/dev/null || echo 0)
if [[ "$CUR_CNT" -eq 1 ]]; then
  RD=$(aws cur describe-report-definitions --region us-east-1 --query "ReportDefinitions[?ReportName=='$REPORT_NAME']|[0]" --output json)
  BUCKET=$(echo "$RD" | jq -r '.S3Bucket' 2>/dev/null || echo "")
  PREFIX=$(echo "$RD" | jq -r '.S3Prefix' 2>/dev/null || echo "")
  if [[ "$BUCKET" == "$BUCKET_NAME" && "$PREFIX" == "$S3_PREFIX" ]]; then
    ok "CUR '$REPORT_NAME' target matches s3://$BUCKET_NAME/$S3_PREFIX"
  else
    fail "CUR '$REPORT_NAME' points to s3://$BUCKET/$PREFIX, expected s3://$BUCKET_NAME/$S3_PREFIX"
  fi
else
  fail "CUR '$REPORT_NAME' not found in us-east-1"
fi

section "Cost Allocation Tags activation"
CAT=$(aws ce list-cost-allocation-tags --region "$AWS_REGION" --status Active --query 'CostAllocationTags[].TagKey' --output json 2>/dev/null || echo "[]")
if echo "$CAT" | grep -q "\"$TAG_KEY_1\""; then ok "Active: $TAG_KEY_1"; else warn "Inactive: $TAG_KEY_1 (activate in CE)"; fi
if echo "$CAT" | grep -q "\"$TAG_KEY_2\""; then ok "Active: $TAG_KEY_2"; else warn "Inactive: $TAG_KEY_2 (activate in CE)"; fi

section "IAM role and trust policy"
if aws iam get-role --role-name "$EXPECTED_ROLE_NAME" >/dev/null 2>&1; then
  ROLE_ARN=$(aws iam get-role --role-name "$EXPECTED_ROLE_NAME" --query Role.Arn --output text)
  ok "Role exists: $ROLE_ARN"
  TRUST=$(aws iam get-role --role-name "$EXPECTED_ROLE_NAME" --query Role.AssumeRolePolicyDocument | jq -r '.Statement[0].Condition.StringEquals["sts:ExternalId"]' 2>/dev/null || echo "")
  PRINC=$(aws iam get-role --role-name "$EXPECTED_ROLE_NAME" --query Role.AssumeRolePolicyDocument | jq -r '.Statement[0].Principal.AWS' 2>/dev/null || echo "")
  if [[ -n "$EXPECTED_EXTERNAL_ID" ]]; then
    if [[ "$TRUST" == "$EXPECTED_EXTERNAL_ID" ]]; then ok "External ID matches"; else fail "External ID mismatch (trust has '$TRUST')"; fi
  else
    [[ -n "$TRUST" ]] && ok "External ID present" || warn "External ID not detected in trust policy"
  fi
  [[ "$PRINC" == "arn:aws:iam::$RH_ACCOUNT_ID:root" ]] && ok "Trusted principal is Red Hat account ($RH_ACCOUNT_ID)" || warn "Unexpected trusted principal: $PRINC"
  # Policy attachment
  if aws iam list-attached-role-policies --role-name "$EXPECTED_ROLE_NAME" --query "AttachedPolicies[?ends_with(PolicyName,'ELS_Metering_Access_Policy')]|length(@)" --output text | grep -q '^1$'; then
    ok "Required policy attached"
  else
    warn "Required policy not attached to role"
  fi
else
  fail "Role not found: $EXPECTED_ROLE_NAME"
fi

echo
if [[ "$failures" -gt 0 ]]; then
  echo "Validation finished with $failures failure(s), $warns warning(s)."
  exit 2
else
  echo "Validation finished OK with $warns warning(s)."
fi

