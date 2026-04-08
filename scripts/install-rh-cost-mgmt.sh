#!/usr/bin/env bash
set -euo pipefail

# Installer for Red Hat Cost Management AWS bootstrap
# Downloads selected script + checksum, verifies integrity, then executes it.
#
# Intended one-liner usage:
#   curl -fsSL "<BASE_URL>/install-rh-cost-mgmt.sh" | bash -s -- --base-url "<BASE_URL>" [--tool setup|validate|teardown] [--] [script args...]
#
# Where <BASE_URL> hosts:
#   - setup_rh_cost_mgmt.sh
#   - setup_rh_cost_mgmt.sh.sha256   (format: "<hash>  setup_rh_cost_mgmt.sh")
#
# Example:
#   curl -fsSL "https://your.cdn.example.com/rh-cost-mgmt/install-rh-cost-mgmt.sh" | \
#     bash -s -- --base-url "https://your.cdn.example.com/rh-cost-mgmt" --tool setup -- --wizard
#   curl -fsSL "https://your.cdn.example.com/rh-cost-mgmt/install-rh-cost-mgmt.sh" | \
#     bash -s -- --base-url "https://your.cdn.example.com/rh-cost-mgmt" --tool validate -- <BUCKET> <REGION>
#   curl -fsSL "https://your.cdn.example.com/rh-cost-mgmt/install-rh-cost-mgmt.sh" | \
#     bash -s -- --base-url "https://your.cdn.example.com/rh-cost-mgmt" --tool teardown -- <BUCKET> <REGION> --yes
#
# Note: arguments after a standalone `--` are passed to the setup script.

BASE_URL=""
TOOL="setup"
FORWARD_ARGS=()

have() { command -v "$1" >/dev/null 2>&1; }
die() { echo "Error: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  install-rh-cost-mgmt.sh --base-url "<BASE_URL>" [--tool setup|validate|teardown] [--] [script args]

Examples:
  curl -fsSL "<BASE_URL>/install-rh-cost-mgmt.sh" | bash -s -- --base-url "<BASE_URL>" --tool setup -- --wizard
  curl -fsSL "<BASE_URL>/install-rh-cost-mgmt.sh" | bash -s -- --base-url "<BASE_URL>" --tool validate -- rh-bucket us-east-1
  curl -fsSL "<BASE_URL>/install-rh-cost-mgmt.sh" | bash -s -- --base-url "<BASE_URL>" --tool teardown -- rh-bucket us-east-1 --yes
EOF
}

while (( "$#" )); do
  case "${1:-}" in
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --tool) TOOL="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; FORWARD_ARGS+=("$@"); break ;;
    *) FORWARD_ARGS+=("$1"); shift ;;
  esac
done

[[ -n "$BASE_URL" ]] || die "--base-url is required"
[[ "$TOOL" =~ ^(setup|validate|teardown)$ ]] || die "--tool must be setup|validate|teardown"
have curl || die "curl is required"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

script_name="setup_rh_cost_mgmt.sh"
[[ "$TOOL" == "validate" ]] && script_name="validate_rh_cost_mgmt.sh"
[[ "$TOOL" == "teardown" ]] && script_name="teardown_rh_cost_mgmt.sh"

script="$tmpdir/$script_name"
sumfile="$tmpdir/$script_name.sha256"

echo "=> Downloading $script_name..."
curl -fsSL "$BASE_URL/$script_name" -o "$script"
chmod +x "$script"

echo "=> Downloading checksum..."
curl -fsSL "$BASE_URL/$script_name.sha256" -o "$sumfile"

echo "=> Verifying checksum..."
if have sha256sum; then
  # Rewrite line to reference local file path
  awk -v f="$(basename "$script")" '{print $1"  "f}' "$sumfile" | (cd "$tmpdir" && sha256sum -c -)
elif have shasum; then
  awk -v f="$(basename "$script")" '{print $1"  "f}' "$sumfile" | (cd "$tmpdir" && shasum -a 256 -c -)
else
  die "Neither sha256sum nor shasum found for verification."
fi

echo "=> Running $script_name $([[ ${#FORWARD_ARGS[@]} -gt 0 ]] && printf '(args: %q )' "${FORWARD_ARGS[@]}")"
"$script" "${FORWARD_ARGS[@]}"

