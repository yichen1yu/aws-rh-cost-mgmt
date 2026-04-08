#!/usr/bin/env bash
set -euo pipefail

# Teardown AWS resources created by setup_rh_cost_mgmt.sh
# WARNING: This deletes IAM role/policy and CUR definition. Optionally deletes the bucket.
#
# Usage:
#   ./teardown_rh_cost_mgmt.sh <BUCKET_NAME> <AWS_REGION> [--remove-bucket] [--yes]
#
# Prompts for confirmation unless --yes is supplied.

REPORT_NAME="koku"
S3_PREFIX="cost"
ROLE_NAME="RH_ELS_Metering_Role"
POLICY_NAME="ELS_Metering_Access_Policy"

die() { echo "Error: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
confirm() {
  local prompt="$1"
  if [[ "${ASSUME_YES:-0}" -eq 1 ]]; then return 0; fi
  read -rp "$prompt [y/N]: " ans < /dev/tty
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <BUCKET_NAME> <AWS_REGION> [--remove-bucket] [--yes]" >&2
  exit 1
fi

BUCKET_NAME="$1"; shift
AWS_REGION="$1"; shift
REMOVE_BUCKET=0
ASSUME_YES=0
while (( "$#" )); do
  case "${1:-}" in
    --remove-bucket) REMOVE_BUCKET=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    *) die "Unknown flag: $1" ;;
  esac
done

have aws || die "aws CLI required"
aws sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials not configured or insufficient"

echo "This will remove:"
echo " - CUR report '$REPORT_NAME' (us-east-1)"
echo " - IAM role '$ROLE_NAME' and policy '$POLICY_NAME'"
[[ "$REMOVE_BUCKET" -eq 1 ]] && echo " - Bucket s3://$BUCKET_NAME (and all objects under $S3_PREFIX/)"
confirm "Proceed?" || { echo "Aborted."; exit 0; }

echo "=> Removing CUR report (if exists)"
if aws cur describe-report-definitions --region us-east-1 --query "ReportDefinitions[?ReportName=='$REPORT_NAME']|length(@)" --output text 2>/dev/null | grep -q '^1$'; then
  aws cur delete-report-definition --region us-east-1 --report-name "$REPORT_NAME" || true
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME"

echo "=> Detaching and deleting IAM role/policy (if exist)"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  # Detach all policies
  for arn in $(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$arn" || true
  done
  aws iam delete-role --role-name "$ROLE_NAME" || true
fi

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  # Delete non-default versions
  for v in $(aws iam list-policy-versions --policy-arn "$POLICY_ARN" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$v" || true
  done
  aws iam delete-policy --policy-arn "$POLICY_ARN" || true
fi

if [[ "$REMOVE_BUCKET" -eq 1 ]]; then
  echo "=> Emptying and deleting s3://$BUCKET_NAME (this may take a while)"
  aws s3 rm "s3://$BUCKET_NAME/$S3_PREFIX/" --recursive || true
  aws s3api delete-bucket --bucket "$BUCKET_NAME" || true
fi

echo "Teardown complete."

