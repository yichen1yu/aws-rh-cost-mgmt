# Red Hat Cost Management / ELS Metering — AWS Bootstrap

Automates the AWS-side setup needed for integrating AWS cost data and RHEL ELS metering with the [Red Hat Hybrid Cloud Console](https://console.redhat.com).

For the full step-by-step walkthrough (including prerequisites, troubleshooting, and manual steps), see the [Integration Guide](docs/AWS-Red-Hat-Console-Integration-Guide.md).

## What it does

- S3 bucket creation for CUR
- Defines the CUR report "koku" (hourly, resources, gzip, Redshift/QuickSight)
- EC2 instance tagging across regions:
  - `com_redhat_rhel=7`
  - `com_redhat_rhel_addon=ELS`
- Activates the two Cost Allocation Tags
- Creates an IAM policy and role trusted to the Red Hat account with your External ID

## Two-phase workflow

AWS requires up to 24 hours for Cost Allocation Tags and CUR data to become available. The script splits setup into two phases to handle this gracefully:

| Phase | When | What it does |
|-------|------|-------------|
| **Phase 1** | Run immediately | Creates S3 bucket, CUR report, IAM role/policy, tags EC2 instances. Saves all values to a state file. |
| **Phase 2** | Run after ~24 hours | Activates Cost Allocation Tags, validates CUR delivery, checks IAM setup. |

If the Red Hat wizard is re-run and generates a **new External ID**, the script can update the IAM role trust in one command — no need to redo the full setup.

What remains manual:
- Subscribe the correct ELS Marketplace listing (per your locale).
- Paste the generated Role ARN and your External ID into the Red Hat Hybrid Cloud Console wizard.

## Quick start

### Option A: Run in AWS CloudShell (no local setup)

No local AWS CLI or credential setup needed. Log into the AWS Console (including via Red Hat IdP → Select a role), open **AWS CloudShell**, then run:

```bash
curl -fsSL "https://raw.githubusercontent.com/yichen1yu/aws-rh-cost-mgmt/main/scripts/setup_rh_cost_mgmt.sh" -o setup_rh_cost_mgmt.sh
chmod +x setup_rh_cost_mgmt.sh
./setup_rh_cost_mgmt.sh --wizard
```

### Option B: Clone and run locally

```bash
git clone https://github.com/yichen1yu/aws-rh-cost-mgmt.git
cd aws-rh-cost-mgmt

# Phase 1: Initial setup (guided wizard)
./scripts/setup_rh_cost_mgmt.sh --wizard

# Complete the Red Hat Hybrid Cloud Console wizard with the output values.
# Wait ~24 hours for Cost Allocation Tags and CUR data.

# Phase 2: Activate tags and validate
./scripts/setup_rh_cost_mgmt.sh --phase2
```

## Running from Cursor with AWS MCP (recommended for IDE users)

If you use [Cursor](https://cursor.com), you can install the **AWS MCP** so the AI agent can run the setup script and all AWS commands for you — directly from the IDE, no terminal switching needed.

### One-time setup

Add this to your Cursor MCP config (`~/.cursor/mcp.json`):

```json
{
  "mcpServers": {
    "aws-mcp": {
      "command": "uvx",
      "args": [
        "mcp-proxy-for-aws@latest",
        "https://aws-mcp.us-east-1.api.aws/mcp",
        "--metadata", "AWS_REGION=us-east-1"
      ]
    }
  }
}
```

> Install `uvx` with `pip install uv` or `brew install uv` if needed. If it's not on your PATH, use the full path (e.g. `/Users/<you>/.local/bin/uvx`).

Restart Cursor after saving. The AWS MCP server will appear in Cursor's MCP panel.

### How it works

The AWS MCP doesn't replace the integration scripts — it gives the AI agent the ability to **execute the scripts and AWS CLI commands on your behalf**. The integration logic (what resources to create, what settings to use, how to configure IAM trust) still comes from the scripts in this repo.

With the AWS MCP active, you can open the agent chat in Cursor and ask it to run the setup. The agent will:
1. Execute `./scripts/setup_rh_cost_mgmt.sh --wizard` or the equivalent AWS commands via MCP
2. Show you the results inline (Role ARN, bucket, etc.)
3. Run `--phase2` when you come back after 24 hours
4. Troubleshoot any errors on the spot using the AWS MCP tools

This means no copy-pasting CLI commands and no switching between terminals and docs. See the [full details in the Integration Guide](docs/AWS-Red-Hat-Console-Integration-Guide.md#2-running-from-cursor-with-aws-mcp).

## Contents

| File | Description |
|------|-------------|
| `scripts/setup_rh_cost_mgmt.sh` | Main setup script (Phase 1, Phase 2, and External ID update) |
| `scripts/validate_rh_cost_mgmt.sh` | Standalone validation script |
| `scripts/teardown_rh_cost_mgmt.sh` | Removes all AWS resources created by setup |
| `scripts/install-rh-cost-mgmt.sh` | Installer that verifies checksum and runs the setup |
| `scripts/*.sha256` | SHA-256 checksums for integrity verification |
| `docs/AWS-Red-Hat-Console-Integration-Guide.md` | Full step-by-step integration guide |

## Usage

```bash
./scripts/setup_rh_cost_mgmt.sh <BUCKET_NAME> <AWS_REGION> <EXTERNAL_ID> [TAG_REGIONS]
```

Flags:
- `--wizard`: Guided prompts for all inputs
- `--plan`: Dry run; prints intended actions and exits
- `--output json`: Prints machine-readable JSON (RoleArn, ExternalId, Bucket, Region, Prefix)
- `--update-external-id <ID>`: Updates IAM role trust with a new External ID
- `--phase2`: Runs delayed steps (activate tags, validate CUR, check IAM)
- `--show`: Displays saved wizard values from state file

### Examples

```bash
# Guided setup (Phase 1)
./scripts/setup_rh_cost_mgmt.sh --wizard

# Non-interactive with EC2 tagging across multiple regions
./scripts/setup_rh_cost_mgmt.sh rh-cost-mgmt-reports-123456789012-us-east-1 us-east-1 abcdef-1234 us-east-1,us-west-2

# Dry run
./scripts/setup_rh_cost_mgmt.sh rh-bucket us-east-1 abc --plan

# JSON output for automation
./scripts/setup_rh_cost_mgmt.sh rh-bucket us-east-1 abc --output json

# Update External ID (if Red Hat wizard generates a new one)
./scripts/setup_rh_cost_mgmt.sh --update-external-id <NEW_EXTERNAL_ID>

# Phase 2: Activate tags and validate (after ~24 hours)
./scripts/setup_rh_cost_mgmt.sh --phase2

# Show saved wizard values
./scripts/setup_rh_cost_mgmt.sh --show
```

## State file

The script saves all wizard values to `~/.rh-cost-mgmt-state.json` after Phase 1. This file is used by `--phase2`, `--update-external-id`, and `--show` so you don't need to remember or re-enter values.

## Handling External ID changes

If you remove and re-add the integration in the Red Hat Hybrid Cloud Console, the wizard generates a **new External ID**. Instead of re-running the full setup:

```bash
./scripts/setup_rh_cost_mgmt.sh --update-external-id <NEW_EXTERNAL_ID>
```

## Validation

```bash
# Via Phase 2 (recommended — uses saved state)
./scripts/setup_rh_cost_mgmt.sh --phase2

# Standalone
./scripts/validate_rh_cost_mgmt.sh <BUCKET_NAME> <AWS_REGION> [ROLE_NAME] [EXTERNAL_ID]
```

## Teardown

```bash
./scripts/teardown_rh_cost_mgmt.sh <BUCKET_NAME> <AWS_REGION> [--remove-bucket] [--yes]
```

Removes the CUR definition and IAM artifacts; optionally empties and deletes the bucket.

## Required AWS permissions

- S3: `s3:Get*`, `s3:List*`, `s3:CreateBucket`, `s3:PutBucketPolicy`
- CUR: `cur:PutReportDefinition`, `cur:DescribeReportDefinitions` (us-east-1 scoped)
- CE: `ce:UpdateCostAllocationTagsStatus`, `ce:ListCostAllocationTags`, `ce:GetCostAndUsage`, `ce:GetCostForecast`
- EC2: `ec2:CreateTags`, `ec2:DescribeInstances`
- IAM: Create/Update policy and role; attach policy
- Organizations: `organizations:List*`, `organizations:Describe*` (if applicable)

## Security

- The IAM trust policy restricts assume-role by requiring the External ID you provide.
- Installer verifies the setup script via SHA-256 before running it.
- The state file contains the External ID — keep it secure (same machine, same user).

## License

Internal use. See your organization's policies.
