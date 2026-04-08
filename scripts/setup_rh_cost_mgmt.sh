#!/usr/bin/env bash
set -euo pipefail

# Red Hat Cost Management / ELS metering AWS bootstrap
# Automates:
# - S3 bucket for CUR
# - CUR report "koku" (hourly, resources, gzip, Redshift/QuickSight)
# - Optional EC2 tagging (com_redhat_rhel=7, com_redhat_rhel_addon=ELS)
# - Activate Cost Allocation Tags
# - Create/Update IAM policy and role trusted to Red Hat account with provided External ID
# Outputs Role ARN and CUR details for use in Red Hat Hybrid Cloud Console wizard.
#
# Requirements:
# - AWS CLI v2 authenticated with permissions for S3, CUR, CE, IAM, EC2 (if tagging)
# - bash, jq (optional for pretty JSON)
#
# Usage:
#   ./setup_rh_cost_mgmt.sh <BUCKET_NAME> <AWS_REGION> <EXTERNAL_ID> [TAG_REGIONS]
# Flags:
#   --wizard                       Guided prompts for inputs
#   --plan                         Dry run; show intended actions and exit
#   --output json                  Machine-readable output
#   --update-external-id <ID>      Update IAM role trust with a new External ID
#   --phase2                       Run delayed steps (activate tags + validate)
#   --show                         Show saved wizard values from state file
#   -h | --help                    Show help
#
# Examples:
#   ./setup_rh_cost_mgmt.sh rh-cost-mgmt-reports-123456789012-us-east-1 us-east-1 abcdef-1234
#   ./setup_rh_cost_mgmt.sh --wizard
#   ./setup_rh_cost_mgmt.sh --update-external-id <NEW_EXTERNAL_ID>
#   ./setup_rh_cost_mgmt.sh --phase2
#   ./setup_rh_cost_mgmt.sh --show

REPORT_NAME="koku"
S3_PREFIX="cost"
CUR_TIME_UNIT="HOURLY"
CUR_COMPRESSION="GZIP"
CUR_ARTIFACTS='["REDSHIFT","QUICKSIGHT"]'
RH_ACCOUNT_ID="589173575009"
POLICY_NAME="ELS_Metering_Access_Policy"
ROLE_NAME="RH_ELS_Metering_Role"
TAG_KEY_1="com_redhat_rhel"
TAG_VAL_1="7"
TAG_KEY_2="com_redhat_rhel_addon"
TAG_VAL_2="ELS"

STATE_FILE="${HOME}/.rh-cost-mgmt-state.json"

WIZARD=0
PLAN=0
OUTPUT="text"
UPDATE_EXT_ID=""
PHASE2=0
SHOW=0

usage() {
  cat <<'USAGE'
Usage:
  setup_rh_cost_mgmt.sh <BUCKET_NAME> <AWS_REGION> <EXTERNAL_ID> [TAG_REGIONS]

Flags:
  --wizard                       Guided prompts for inputs
  --plan                         Dry run; show intended actions and exit
  --output json                  Machine-readable output
  --update-external-id <ID>      Update IAM role trust with a new External ID
  --phase2                       Run delayed steps (activate tags + validate)
  --show                         Show saved wizard values from state file
  -h | --help                    Show help

Workflow:
  Phase 1 (run immediately):
    ./setup_rh_cost_mgmt.sh --wizard
    Creates S3 bucket, CUR, IAM role, tags EC2 instances.
    Complete the Red Hat wizard with the output values.

  Phase 2 (run after ~24 hours):
    ./setup_rh_cost_mgmt.sh --phase2
    Activates Cost Allocation Tags and runs validation.

  If Red Hat wizard generates a new External ID:
    ./setup_rh_cost_mgmt.sh --update-external-id <NEW_ID>
    Updates the IAM role trust policy to match.
USAGE
}

die() { echo "Error: $*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

json_out() {
  local payload="$1"
  if [[ "$OUTPUT" == "json" ]]; then
    if have jq; then echo "$payload" | jq '.'; else echo "$payload"; fi
  fi
}

preflight() {
  have aws || die "aws CLI is required (https://docs.aws.amazon.com/cli/)."
  aws sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials not configured or lack STS permissions. Run 'aws login' first."
}

account_id() { aws sts get-caller-identity --query Account --output text; }
exists_bucket() { aws s3api head-bucket --bucket "$1" >/dev/null 2>&1; }
cur_defined() { aws cur describe-report-definitions --region us-east-1 --query "ReportDefinitions[?ReportName=='$REPORT_NAME'] | length(@)" --output text 2>/dev/null || echo 0; }

# --- State file management ---

save_state() {
  local role_arn="$1" external_id="$2" bucket="$3" region="$4"
  cat > "$STATE_FILE" <<EOF
{
  "role_arn": "$role_arn",
  "external_id": "$external_id",
  "bucket": "$bucket",
  "region": "$region",
  "prefix": "$S3_PREFIX",
  "role_name": "$ROLE_NAME",
  "policy_name": "$POLICY_NAME",
  "rh_account_id": "$RH_ACCOUNT_ID",
  "saved_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  echo "=> State saved to $STATE_FILE"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || die "No state file found at $STATE_FILE. Run the setup first."
  if have jq; then
    STATE_ROLE_ARN=$(jq -r '.role_arn' "$STATE_FILE")
    STATE_EXTERNAL_ID=$(jq -r '.external_id' "$STATE_FILE")
    STATE_BUCKET=$(jq -r '.bucket' "$STATE_FILE")
    STATE_REGION=$(jq -r '.region' "$STATE_FILE")
  else
    STATE_ROLE_ARN=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['role_arn'])")
    STATE_EXTERNAL_ID=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['external_id'])")
    STATE_BUCKET=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['bucket'])")
    STATE_REGION=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['region'])")
  fi
}

show_state() {
  [[ -f "$STATE_FILE" ]] || die "No state file found at $STATE_FILE. Run the setup first."
  echo
  echo "=========================================="
  echo "  Red Hat Hybrid Cloud Console Wizard Values"
  echo "=========================================="
  if have jq; then
    echo "  Role ARN:    $(jq -r '.role_arn' "$STATE_FILE")"
    echo "  External ID: $(jq -r '.external_id' "$STATE_FILE")"
    echo "  S3 Bucket:   $(jq -r '.bucket' "$STATE_FILE")"
    echo "  AWS Region:  $(jq -r '.region' "$STATE_FILE")"
    echo "=========================================="
    echo "  Saved at:    $(jq -r '.saved_at' "$STATE_FILE")"
  else
    python3 -c "
import json
s = json.load(open('$STATE_FILE'))
print(f\"  Role ARN:    {s['role_arn']}\")
print(f\"  External ID: {s['external_id']}\")
print(f\"  S3 Bucket:   {s['bucket']}\")
print(f\"  AWS Region:  {s['region']}\")
print('==========================================')
print(f\"  Saved at:    {s['saved_at']}\")
"
  fi
  echo
}

# --- Core functions ---

ensure_bucket() {
  local bucket="$1" region="$2"
  if ! exists_bucket "$bucket"; then
    echo "=> Creating S3 bucket: s3://$bucket (region: $region)"
    if [[ "$region" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "$bucket"
    else
      aws s3api create-bucket --bucket "$bucket" --create-bucket-configuration "LocationConstraint=$region"
    fi
  else
    echo "=> Bucket exists: s3://$bucket"
  fi
  local acct
  acct=$(account_id)
  echo "=> Setting bucket policy for CUR service (billingreports.amazonaws.com)"
  aws s3api put-bucket-policy --bucket "$bucket" --policy "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Principal\": {\"Service\": \"billingreports.amazonaws.com\"},
        \"Action\": [\"s3:GetBucketAcl\", \"s3:GetBucketPolicy\"],
        \"Resource\": \"arn:aws:s3:::${bucket}\",
        \"Condition\": {\"StringEquals\": {\"aws:SourceArn\": \"arn:aws:cur:us-east-1:${acct}:definition/*\", \"aws:SourceAccount\": \"${acct}\"}}
      },
      {
        \"Effect\": \"Allow\",
        \"Principal\": {\"Service\": \"billingreports.amazonaws.com\"},
        \"Action\": \"s3:PutObject\",
        \"Resource\": \"arn:aws:s3:::${bucket}/*\",
        \"Condition\": {\"StringEquals\": {\"aws:SourceArn\": \"arn:aws:cur:us-east-1:${acct}:definition/*\", \"aws:SourceAccount\": \"${acct}\"}}
      }
    ]
  }"
}

ensure_cur() {
  local bucket="$1" region="$2"
  echo "=> Ensuring CUR report '$REPORT_NAME' to s3://$bucket/$S3_PREFIX (CUR API is us-east-1 scoped)"
  if [[ "$(cur_defined)" -eq 0 ]]; then
    aws cur put-report-definition --region us-east-1 --report-definition "{
      \"ReportName\": \"$REPORT_NAME\",
      \"TimeUnit\": \"$CUR_TIME_UNIT\",
      \"Format\": \"textORcsv\",
      \"Compression\": \"$CUR_COMPRESSION\",
      \"AdditionalSchemaElements\": [\"RESOURCES\"],
      \"S3Bucket\": \"$bucket\",
      \"S3Prefix\": \"$S3_PREFIX\",
      \"S3Region\": \"$region\",
      \"AdditionalArtifacts\": $CUR_ARTIFACTS,
      \"RefreshClosedReports\": true,
      \"ReportVersioning\": \"OVERWRITE_REPORT\"
    }"
  else
    echo "   CUR '$REPORT_NAME' already present; skipping."
  fi
}

tag_instances() {
  local regions_csv="$1"
  [[ -z "${regions_csv:-}" ]] && { echo "=> Skipping instance tagging (no TAG_REGIONS provided)"; return 0; }
  IFS=',' read -r -a REGIONS <<< "$regions_csv"
  for R in "${REGIONS[@]}"; do
    echo "=> Tagging running EC2 instances in $R with $TAG_KEY_1=$TAG_VAL_1 and $TAG_KEY_2=$TAG_VAL_2"
    IDS=$(aws ec2 describe-instances --region "$R" --query "Reservations[].Instances[?State.Name=='running'].InstanceId" --output text)
    if [[ -n "${IDS// /}" ]]; then
      aws ec2 create-tags --region "$R" --resources $IDS --tags Key="$TAG_KEY_1",Value="$TAG_VAL_1" Key="$TAG_KEY_2",Value="$TAG_VAL_2"
    else
      echo "   No running instances found in $R; skipping."
    fi
  done
}

activate_cat() {
  local region="$1"
  echo "=> Checking Cost Allocation Tags..."
  local tag_list
  tag_list=$(aws ce list-cost-allocation-tags --region "$region" \
    --query "CostAllocationTags[?TagKey=='$TAG_KEY_1' || TagKey=='$TAG_KEY_2'].{Key:TagKey,Status:Status}" \
    --output text 2>/dev/null || echo "")

  if [[ -z "$tag_list" ]]; then
    echo "   Tags not yet discovered by Cost Explorer."
    echo "   This is normal — it can take up to 24 hours after tagging EC2 instances."
    echo "   Run './setup_rh_cost_mgmt.sh --phase2' later to activate them."
    return 0
  fi

  echo "=> Activating Cost Allocation Tags in region: $region"
  local result
  result=$(aws ce update-cost-allocation-tags-status --region "$region" --cost-allocation-tags-status "[
    {\"TagKey\":\"$TAG_KEY_1\",\"Status\":\"Active\"},
    {\"TagKey\":\"$TAG_KEY_2\",\"Status\":\"Active\"}
  ]" 2>&1) || true

  if echo "$result" | grep -q "Tag keys not found"; then
    echo "   Tags not yet discovered by Cost Explorer."
    echo "   Run './setup_rh_cost_mgmt.sh --phase2' later to activate them."
  else
    echo "   Cost Allocation Tags activated."
  fi
}

upsert_iam() {
  local bucket="$1" external_id="$2"
  local acct role_arn policy_arn
  acct="$(account_id)"
  local policy_doc trust_doc
  policy_doc="$(mktemp)"; trust_doc="$(mktemp)"
  cat > "$policy_doc" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BucketAccess",
      "Effect": "Allow",
      "Action": [
        "s3:Get*",
        "s3:List*"
      ],
      "Resource": [
        "arn:aws:s3:::$bucket",
        "arn:aws:s3:::$bucket/*"
      ]
    },
    {
      "Sid": "CostAndCUR",
      "Effect": "Allow",
      "Action": [
        "cur:DescribeReportDefinitions",
        "ce:GetCostAndUsage",
        "ce:GetCostForecast",
        "ce:GetReservationUtilization",
        "ce:GetUsageForecast",
        "organizations:List*",
        "organizations:Describe*"
      ],
      "Resource": "*"
    }
  ]
}
EOF
  cat > "$trust_doc" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::$RH_ACCOUNT_ID:root" },
      "Action": "sts:AssumeRole",
      "Condition": { "StringEquals": { "sts:ExternalId": "$external_id" } }
    }
  ]
}
EOF
  echo "=> Creating/Updating IAM policy $POLICY_NAME"
  policy_arn="arn:aws:iam::$acct:policy/$POLICY_NAME"
  if aws iam get-policy --policy-arn "$policy_arn" >/dev/null 2>&1; then
    local versions
    versions=$(aws iam list-policy-versions --policy-arn "$policy_arn" --query 'Versions | length(@)' --output text)
    if [[ "$versions" -ge 5 ]]; then
      local oldest
      oldest=$(aws iam list-policy-versions --policy-arn "$policy_arn" \
        --query 'Versions[?IsDefaultVersion==`false`] | sort_by(@, &CreateDate) | [0].VersionId' --output text)
      aws iam delete-policy-version --policy-arn "$policy_arn" --version-id "$oldest" >/dev/null
    fi
    aws iam create-policy-version --policy-arn "$policy_arn" --policy-document "file://$policy_doc" --set-as-default >/dev/null
  else
    policy_arn=$(aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "file://$policy_doc" --query Policy.Arn --output text)
  fi
  echo "=> Creating/Updating role $ROLE_NAME"
  if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "file://$trust_doc"
  else
    aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "file://$trust_doc" >/dev/null
  fi
  if ! aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query "AttachedPolicies[?PolicyArn=='$policy_arn'] | length(@)" --output text | grep -q '^1$'; then
    aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$policy_arn"
  fi
  role_arn=$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)
  rm -f "$policy_doc" "$trust_doc"
  echo "$role_arn"
}

# --- Update External ID ---

do_update_external_id() {
  local new_id="$1"
  preflight
  echo "=> Updating IAM role $ROLE_NAME trust policy with new External ID"
  local trust_doc
  trust_doc="$(mktemp)"
  cat > "$trust_doc" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::$RH_ACCOUNT_ID:root" },
      "Action": "sts:AssumeRole",
      "Condition": { "StringEquals": { "sts:ExternalId": "$new_id" } }
    }
  ]
}
EOF
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "file://$trust_doc"
  rm -f "$trust_doc"
  echo "   Done. IAM role now trusts External ID: $new_id"

  if [[ -f "$STATE_FILE" ]]; then
    load_state
    save_state "$STATE_ROLE_ARN" "$new_id" "$STATE_BUCKET" "$STATE_REGION"
  fi

  echo
  echo "You can now complete the Red Hat wizard. The role will accept the new External ID."
}

# --- Phase 2: Delayed steps ---

do_phase2() {
  preflight
  load_state
  echo "== Phase 2: Delayed activation and validation =="
  echo "   Using saved state from $STATE_FILE"
  echo "   Bucket:      $STATE_BUCKET"
  echo "   Region:      $STATE_REGION"
  echo "   Role ARN:    $STATE_ROLE_ARN"
  echo "   External ID: $STATE_EXTERNAL_ID"
  echo

  echo "--- Step 1: Activate Cost Allocation Tags ---"
  activate_cat "$STATE_REGION"
  echo

  echo "--- Step 2: Check CUR delivery ---"
  local cur_objects
  cur_objects=$(aws s3 ls "s3://$STATE_BUCKET/$S3_PREFIX/" --recursive 2>/dev/null | head -5 || true)
  if [[ -n "$cur_objects" ]]; then
    echo "   CUR data found in bucket:"
    echo "$cur_objects" | sed 's/^/     /'
  else
    echo "   No CUR data yet. First delivery can take up to 24 hours."
  fi
  echo

  echo "--- Step 3: Validate IAM role ---"
  local trust
  trust=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals."sts:ExternalId"' --output text 2>/dev/null || echo "")
  if [[ "$trust" == "$STATE_EXTERNAL_ID" ]]; then
    echo "   IAM role trust policy matches saved External ID."
  else
    echo "   WARNING: IAM role External ID ($trust) does not match saved state ($STATE_EXTERNAL_ID)."
    echo "   If you re-ran the Red Hat wizard, run:"
    echo "     ./setup_rh_cost_mgmt.sh --update-external-id <NEW_ID>"
  fi

  local attached
  attached=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query "AttachedPolicies[?PolicyName=='$POLICY_NAME'] | length(@)" --output text 2>/dev/null || echo "0")
  if [[ "$attached" == "1" ]]; then
    echo "   IAM policy attached."
  else
    echo "   WARNING: Policy $POLICY_NAME is not attached to role $ROLE_NAME."
  fi
  echo

  echo "--- Step 4: Check EC2 tags ---"
  local tagged
  tagged=$(aws ec2 describe-instances --region "$STATE_REGION" \
    --filters "Name=tag:$TAG_KEY_1,Values=$TAG_VAL_1" "Name=tag:$TAG_KEY_2,Values=$TAG_VAL_2" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].[InstanceId]' --output text 2>/dev/null || echo "")
  if [[ -n "$tagged" ]]; then
    echo "   Tagged instances found in $STATE_REGION:"
    echo "$tagged" | sed 's/^/     /'
  else
    echo "   No tagged running instances in $STATE_REGION."
  fi
  echo

  echo "=========================================="
  echo "  Phase 2 complete."
  echo "=========================================="
  show_state
}

# --- Post-run summary ---

post_run_summary() {
  local role_arn="$1" bucket="$2" region="$3" external_id="$4"
  echo
  echo "=========================================="
  echo "  Phase 1 complete"
  echo "=========================================="
  echo
  echo "  Red Hat Hybrid Cloud Console Wizard Values"
  echo "  ------------------------------------------"
  echo "  Role ARN:    $role_arn"
  echo "  External ID: $external_id"
  echo "  S3 Bucket:   $bucket"
  echo "  AWS Region:  $region"
  echo
  echo "  CUR prefix:  s3://$bucket/$S3_PREFIX"
  echo "=========================================="
  echo
  echo "Next steps:"
  echo "  1) Complete the Red Hat Hybrid Cloud Console wizard with the values above"
  echo "  2) Subscribe the required ELS Marketplace listing"
  echo "  3) Wait ~24 hours, then run:"
  echo "       ./setup_rh_cost_mgmt.sh --phase2"
  echo "     to activate Cost Allocation Tags and validate the setup."
  echo
  echo "  If you re-run the Red Hat wizard and get a NEW External ID, run:"
  echo "       ./setup_rh_cost_mgmt.sh --update-external-id <NEW_ID>"
  echo "     to update the IAM role without re-running the full setup."
  echo
  echo "  To see saved values anytime:"
  echo "       ./setup_rh_cost_mgmt.sh --show"
}

# --- Parse flags ---

ARGS=()
while (( "$#" )); do
  case "${1:-}" in
    --wizard) WIZARD=1; shift ;;
    --plan) PLAN=1; shift ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --update-external-id) UPDATE_EXT_ID="${2:-}"; shift 2 ;;
    --phase2) PHASE2=1; shift ;;
    --show) SHOW=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -* ) die "Unknown flag: $1" ;;
    *  ) ARGS+=("$1"); shift ;;
  esac
done

# --- Handle --show ---
if [[ "$SHOW" -eq 1 ]]; then
  show_state
  exit 0
fi

# --- Handle --update-external-id ---
if [[ -n "$UPDATE_EXT_ID" ]]; then
  do_update_external_id "$UPDATE_EXT_ID"
  exit 0
fi

# --- Handle --phase2 ---
if [[ "$PHASE2" -eq 1 ]]; then
  do_phase2
  exit 0
fi

# --- Handle --plan (generic) ---
if [[ "$PLAN" -eq 1 && "$WIZARD" -eq 0 && "${#ARGS[@]}" -lt 3 ]]; then
  cat <<EOF
Plan (generic):
  - Ensure S3 bucket: s3://<BUCKET_NAME> (region: <AWS_REGION>)
  - Ensure CUR '$REPORT_NAME' -> s3://<BUCKET_NAME>/$S3_PREFIX (us-east-1 API)
  - Tag EC2 instances in: <TAG_REGIONS or none>
  - Activate Cost Allocation Tags in: <AWS_REGION> (if ready; otherwise deferred to --phase2)
  - Upsert IAM policy '$POLICY_NAME' and role '$ROLE_NAME' (trust: Red Hat $RH_ACCOUNT_ID, ExternalId)
  - Save state to $STATE_FILE
  - Output Role ARN and summary
Manual:
  - Subscribe ELS Marketplace listing
  - Paste Role ARN + External ID into RH Console wizard
  - Run --phase2 after ~24 hours
EOF
  exit 0
fi

if [[ "${#ARGS[@]}" -gt 0 ]]; then
  set -- "${ARGS[@]}" "$@"
fi

if [[ "$PLAN" -eq 0 || ( "$PLAN" -eq 1 && "$#" -ge 3 ) || "$WIZARD" -eq 1 ]]; then
  preflight
fi

DEFAULT_REGION="$(aws configure get region || true)"

if [[ "$WIZARD" -eq 1 ]]; then
  echo "== Phase 1: Initial setup (wizard mode) =="
  read -rp "S3 bucket name for CUR [rh-cost-mgmt-reports-$(account_id)-${DEFAULT_REGION:-us-east-1}]: " BUCKET_NAME
  BUCKET_NAME="${BUCKET_NAME:-rh-cost-mgmt-reports-$(account_id)-${DEFAULT_REGION:-us-east-1}}"
  read -rp "AWS region for bucket and CE [${DEFAULT_REGION:-us-east-1}]: " AWS_REGION
  AWS_REGION="${AWS_REGION:-${DEFAULT_REGION:-us-east-1}}"
  read -rp "External ID (from Red Hat wizard): " EXTERNAL_ID
  read -rp "Tagging regions (comma-separated) [leave blank to skip tagging]: " TAG_REGIONS
else
  if [[ $# -lt 3 ]]; then
    usage; exit 1
  fi
  BUCKET_NAME="$1"
  AWS_REGION="$2"
  EXTERNAL_ID="$3"
  TAG_REGIONS="${4:-}"
fi

if [[ "$PLAN" -eq 1 ]]; then
  cat <<EOF
Plan:
  - Ensure S3 bucket: s3://$BUCKET_NAME (region: $AWS_REGION)
  - Ensure CUR '$REPORT_NAME' -> s3://$BUCKET_NAME/$S3_PREFIX (us-east-1 API)
  - Tag EC2 instances in: ${TAG_REGIONS:-<none>}
  - Activate Cost Allocation Tags in: $AWS_REGION (if ready)
  - Upsert IAM policy '$POLICY_NAME' and role '$ROLE_NAME' (trust: Red Hat $RH_ACCOUNT_ID, ExternalId)
  - Save state to $STATE_FILE
Manual:
  - Subscribe ELS Marketplace listing
  - Paste Role ARN + External ID into RH Console wizard
  - Run --phase2 after ~24 hours
EOF
  exit 0
fi

ensure_bucket "$BUCKET_NAME" "$AWS_REGION"
ensure_cur "$BUCKET_NAME" "$AWS_REGION"
tag_instances "${TAG_REGIONS:-}"
activate_cat "$AWS_REGION"
ROLE_ARN="$(upsert_iam "$BUCKET_NAME" "$EXTERNAL_ID")"

save_state "$ROLE_ARN" "$EXTERNAL_ID" "$BUCKET_NAME" "$AWS_REGION"

if [[ "$OUTPUT" == "json" ]]; then
  json_out "{\"RoleArn\":\"$ROLE_ARN\",\"ExternalId\":\"$EXTERNAL_ID\",\"Bucket\":\"$BUCKET_NAME\",\"Region\":\"$AWS_REGION\",\"Prefix\":\"$S3_PREFIX\"}"
else
  post_run_summary "$ROLE_ARN" "$BUCKET_NAME" "$AWS_REGION" "$EXTERNAL_ID"
fi
