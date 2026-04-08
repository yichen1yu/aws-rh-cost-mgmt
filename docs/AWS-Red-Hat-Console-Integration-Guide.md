# AWS and Red Hat Hybrid Cloud Console Integration — Step-by-Step Guide

This guide walks through integrating your AWS account with Red Hat Hybrid Cloud Console for **cost data** and **RHEL ELS metering**. It covers both the automated script flow and the manual steps you must do before and after.

---

## Table of contents

1. [Overview](#1-overview)
2. [Easiest path: Use AWS MCP in Cursor](#2-easiest-path-use-aws-mcp-in-cursor)
3. [Easier path: Run in AWS CloudShell](#3-easier-path-run-in-aws-cloudshell)
4. [Prerequisites (for local run)](#4-prerequisites-for-local-run)
5. [Step-by-step summary](#5-step-by-step-summary)
6. [Detailed steps](#6-detailed-steps)
7. [Script reference](#7-script-reference)
8. [Required AWS permissions](#8-required-aws-permissions)
9. [Troubleshooting](#9-troubleshooting)
10. [After setup](#10-after-setup)

---

## 1. Overview

**What this integration does**

- Sends **AWS Cost and Usage Report (CUR)** data to Red Hat so cost visibility appears in Hybrid Cloud Console.
- Enables **RHEL Extended Lifecycle Support (ELS)** metering by tagging EC2 instances and activating Cost Allocation Tags; Red Hat reads these via the CUR.

**What the scripts automate (AWS side)**

| Step | What the script does |
|------|----------------------|
| S3 | Creates an S3 bucket for the CUR (or uses an existing one). |
| CUR | Creates the CUR report named `koku` (hourly, resources, gzip, Redshift/QuickSight) pointing to your bucket. |
| EC2 tagging | Optionally tags running EC2 instances with `com_redhat_rhel=7` and `com_redhat_rhel_addon=ELS` in chosen regions. |
| Cost Allocation Tags | Activates the two tags in Cost Explorer (when ready). |
| IAM | Creates/updates an IAM policy and role that Red Hat can assume (using your External ID). |

**Two-phase workflow**

The script splits setup into two phases to handle AWS propagation delays (tags, CUR):

| Phase | When | What |
|-------|------|------|
| **Phase 1** | Run immediately | S3, CUR, IAM, EC2 tags. Saves values to `~/.rh-cost-mgmt-state.json`. |
| **Phase 2** | Run after ~24h | Activates Cost Allocation Tags, validates CUR delivery and IAM. |

If the Red Hat wizard is re-run (generating a new External ID), use `--update-external-id` to update the IAM role without redoing the full setup.

**What stays manual**

- Subscribing to the correct ELS Marketplace listing (per your locale).
- In Red Hat Hybrid Cloud Console: pasting the **Role ARN** and **External ID** into the integration wizard.

---

## 2. Easiest path: Use AWS MCP in Cursor

If you use [Cursor](https://cursor.com) as your IDE, the **AWS MCP (Model Context Protocol)** lets the AI agent run AWS CLI commands directly — no terminal, no credential juggling. You describe what you want in natural language and the agent handles all the AWS API calls for you.

### 2.1 One-time setup: Install the AWS MCP server

Add the following to your Cursor MCP configuration file (`~/.cursor/mcp.json`). Create the file if it doesn't exist.

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

> **Note:** If `uvx` is not on your PATH, use the full path (e.g. `/Users/<you>/.local/bin/uvx`). Install it with `pip install uv` or `brew install uv` if needed.

After saving, restart Cursor. The AWS MCP server should appear in Cursor's MCP panel.

### 2.2 AWS credentials

The MCP proxy uses the standard AWS credential chain (environment variables, `~/.aws/credentials`, SSO session, etc.). Make sure you can run `aws sts get-caller-identity` successfully before using the MCP — if your session is expired, log in first:

```bash
aws sso login
```

### 2.3 Run the integration via the AI agent

Once the AWS MCP is active, open Cursor's agent chat and describe what you want. The agent can execute every step of the setup directly. For example:

> **You:** "Run the setup script for Red Hat cost management integration with wizard mode"

Or ask it step by step:

> **You:** "Create an S3 bucket named rh-cost-mgmt-reports-123456789012-us-east-1 in us-east-1"
> **You:** "Create a CUR report named koku pointing to that bucket"
> **You:** "Create the IAM role RH_ELS_Metering_Role trusting Red Hat account 589173575009 with external ID abc-123"
> **You:** "Tag my running EC2 instances with com_redhat_rhel=7 and com_redhat_rhel_addon=ELS"
> **You:** "Activate the Cost Allocation Tags for those tag keys"

The agent uses the AWS MCP's `call_aws` tool to execute each command and shows you the results inline. No copy-pasting CLI commands, no switching to a terminal.

### 2.4 Phase 2 and validation via the agent

After ~24 hours, come back to the agent and ask:

> **You:** "Run phase 2 of the cost management setup — activate the cost allocation tags and validate everything"

The agent will check CUR delivery, activate tags, verify IAM trust, and report the results — all within the chat.

### 2.5 What the AWS MCP provides

| Tool | What it does |
|------|-------------|
| `call_aws` | Execute any AWS CLI command directly (the primary tool) |
| `suggest_aws_commands` | Get command suggestions from a natural language description |
| `read_documentation` | Fetch and read AWS documentation pages |
| `list_regions` | List available AWS regions |
| `get_regional_availability` | Check service availability by region |

### 2.6 Why this is the easiest path

- **No terminal needed** — the AI agent runs all AWS commands through the MCP.
- **No credential copy-paste** — the MCP proxy uses your existing AWS session (same as `aws` CLI).
- **Guided by AI** — the agent understands the integration steps and can troubleshoot errors on the spot.
- **Works with the scripts too** — you can ask the agent to run `./scripts/setup_rh_cost_mgmt.sh --wizard` in the terminal, or have it execute the equivalent AWS commands directly via MCP.

---

## 3. Easier path: Run in AWS CloudShell

You can skip local AWS CLI install and credential setup by running the setup script **inside AWS CloudShell**. When you use the AWS Console in the browser (including logging in via Red Hat IdP and selecting your role, e.g. uxd-testing), CloudShell uses the **same session** — no separate SSO start URL or profile configuration.

**What you need**

1. Log into the **AWS Console** (e.g. via your normal path, including Red Hat IdP → "Select a role" → choose your account/role).
2. Open **AWS CloudShell**: in the AWS Console header, click the terminal icon (CloudShell) to open a browser-based shell.
3. Run the setup script in one of two ways.

**Option A — Script hosted at a URL (one-liner)**

If the script is hosted at a base URL (e.g. your CDN or GitHub raw), run in CloudShell:

```bash
curl -fsSL "<BASE_URL>/setup_rh_cost_mgmt.sh" | bash -s -- --wizard
```

Replace `<BASE_URL>` with the real URL (e.g. `https://raw.githubusercontent.com/your-org/your-repo/main/scripts` or your own host). You will be prompted for bucket name, region, External ID, and optional tagging regions.

**Option B — Script not hosted (copy from repo)**

If you have the script in your repo but don't host it at a public URL:

1. In CloudShell, create the script and paste the contents of `setup_rh_cost_mgmt.sh` (e.g. copy from your repo), then run:

```bash
chmod +x setup_rh_cost_mgmt.sh
./setup_rh_cost_mgmt.sh --wizard
```

Or download it from GitHub (replace `<org>/<repo>` and branch if needed):

```bash
curl -fsSL "https://raw.githubusercontent.com/<org>/<repo>/main/scripts/setup_rh_cost_mgmt.sh" -o setup_rh_cost_mgmt.sh
chmod +x setup_rh_cost_mgmt.sh
./setup_rh_cost_mgmt.sh --wizard
```

**After it runs**

- Copy the four wizard values from the output and paste them into the Red Hat Hybrid Cloud Console wizard.
- After ~24 hours, run `--phase2` to activate tags and validate the setup.

---

## 4. Prerequisites (for local run)

If you run the script **on your laptop or a build server** instead of CloudShell, you need the following.

### 4.1 AWS CLI

- **AWS CLI v2** installed and on your `PATH`.
- Install: [AWS CLI v2 install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) (e.g. macOS: `brew install awscli` or official installer).

### 4.2 AWS credentials

The scripts call the AWS API. You must be authenticated so that `aws sts get-caller-identity` works.

**Option A — AWS SSO (IAM Identity Center)**  
- Your org uses an **AWS SSO start URL** (e.g. `https://d-xxxxxxxxxx.awsapps.com/start`).
- Configure: `aws configure sso` and enter that **AWS** SSO start URL (not a third-party IdP URL).
- Then: `aws sso login --profile <profile-name>` and use `AWS_PROFILE=<profile-name>` when running the scripts.

**Option B — Red Hat IdP → AWS (SAML)**  
- If you only have a **Red Hat** login link (e.g. `https://auth.redhat.com/.../itaws`) that redirects to "Select a role" in AWS, that is **not** the value for `aws configure sso`'s "SSO start URL."  
- Ask your AWS admin for the **AWS SSO start URL** (`*.awsapps.com/start`) for CLI use, or use whatever method your org provides for CLI access (e.g. temporary keys, or a custom script that uses the SAML flow).

**Verify**

```bash
aws sts get-caller-identity
```

If this fails, fix credentials (see [Troubleshooting](#9-troubleshooting)).

### 4.3 Get the External ID from Red Hat

- In **Red Hat Hybrid Cloud Console**, start the cost/metering integration wizard.
- It will show an **External ID**. Copy it; you'll need it when running the setup script.

### 4.4 Optional: `jq`

- For pretty-printed JSON when using `--output json`, install `jq` (e.g. `brew install jq`). Not required for the script to run.

---

## 5. Step-by-step summary

| # | Step | Automated? | Phase |
|---|------|------------|-------|
| 1 | Install/configure AWS CLI and ensure credentials work | Manual | — |
| 2 | Get External ID from Red Hat Hybrid Cloud Console wizard | Manual | — |
| 3 | Run setup script — Phase 1 (wizard or with bucket/region/External ID) | **Script** | 1 |
| 4 | Copy Role ARN + wizard values from script output | Manual | 1 |
| 5 | In Red Hat wizard: paste Role ARN, External ID, S3 Bucket, AWS Region | Manual | 1 |
| 6 | Subscribe to ELS Marketplace listing (per your locale) | Manual | 1 |
| 7 | Wait ~24 hours for CUR delivery and tag discovery | Manual | — |
| 8 | Run `--phase2` to activate tags and validate | **Script** | 2 |
| 9 | *(If needed)* Run `--update-external-id` if Red Hat wizard was re-run | **Script** | — |

---

## 6. Detailed steps

### Step 1: Install and configure AWS CLI (skip if using CloudShell)

1. Install AWS CLI v2 (see [Prerequisites](#41-aws-cli)).
2. If using **AWS SSO**:
   - Run: `aws configure sso`
   - Enter the **AWS SSO start URL** (e.g. `https://d-xxxxxxxxxx.awsapps.com/start`), not a Red Hat IdP URL.
   - Complete the prompts (region, account, role).
3. Log in if using SSO:  
   `aws sso login --profile <your-profile-name>`
4. Verify:  
   `aws sts get-caller-identity`  
   (or `AWS_PROFILE=<profile> aws sts get-caller-identity` if using a named profile).

### Step 2: Get External ID from Red Hat

1. Open Red Hat Hybrid Cloud Console and go to the cost/metering integration (e.g. Subscriptions & Spend or Cost Management).
2. Start the "Add AWS" or "Configure AWS" wizard.
3. The wizard will display an **External ID**. Copy and save it for the next step.

### Step 3: Run the setup script (Phase 1)

**Option A — Guided (wizard)**

```bash
cd /path/to/HCC-cursor-seed
chmod +x scripts/*.sh
./scripts/setup_rh_cost_mgmt.sh --wizard
```

You will be prompted for:

- S3 bucket name (default suggested: `rh-cost-mgmt-reports-<account-id>-<region>`)
- AWS region (e.g. `us-east-1`)
- External ID (from Step 2)
- Optional: comma-separated regions for EC2 tagging (or leave blank to skip)

**Option B — Direct arguments**

```bash
./scripts/setup_rh_cost_mgmt.sh <BUCKET_NAME> <AWS_REGION> <EXTERNAL_ID> [TAG_REGIONS]
```

Example:

```bash
./scripts/setup_rh_cost_mgmt.sh rh-cost-mgmt-reports-123456789012-us-east-1 us-east-1 my-external-id-abc123 us-east-1,us-west-2
```

**Dry run (no changes):**

```bash
./scripts/setup_rh_cost_mgmt.sh --plan
./scripts/setup_rh_cost_mgmt.sh rh-bucket us-east-1 abc --plan
```

**JSON output (for automation):**

```bash
./scripts/setup_rh_cost_mgmt.sh rh-bucket us-east-1 abc --output json
```

### Step 4: Copy the wizard values

After Phase 1 completes, the script prints all four values needed for the Red Hat wizard:

- **Role ARN** (e.g. `arn:aws:iam::123456789012:role/RH_ELS_Metering_Role`)
- **External ID** (the one you provided)
- **S3 Bucket** name
- **AWS Region**

These are also saved to `~/.rh-cost-mgmt-state.json`. View them anytime with:

```bash
./scripts/setup_rh_cost_mgmt.sh --show
```

### Step 5: Complete the Red Hat wizard

1. In the Red Hat Hybrid Cloud Console integration wizard, paste the **Role ARN**, **S3 Bucket**, and **AWS Region**, and confirm the **External ID**.
2. Finish the wizard as prompted.

### Step 6: Subscribe to ELS Marketplace listing

- In AWS (or your cloud marketplace), subscribe to the **RHEL ELS** Marketplace listing that matches your region/locale, as required by Red Hat's documentation.

### Step 7: Wait ~24 hours

- CUR files are delivered to your S3 bucket; this can take **up to 24 hours**.
- Cost Allocation Tags need up to 24 hours to be discovered by Cost Explorer after EC2 instances are tagged.
- Do **not** re-run the Red Hat wizard during this time unless there is an error — re-running generates a new External ID that requires updating the IAM role.

### Step 8: Run Phase 2

After ~24 hours, activate tags and validate everything:

```bash
./scripts/setup_rh_cost_mgmt.sh --phase2
```

Phase 2 checks:
- Cost Allocation Tags are discoverable and activates them
- CUR data has been delivered to S3
- IAM role trust policy matches the saved External ID
- EC2 instances are tagged correctly

### Step 9: Handle External ID changes (if needed)

If you re-ran the Red Hat wizard and it generated a **new** External ID, update the IAM role without re-running the full setup:

```bash
./scripts/setup_rh_cost_mgmt.sh --update-external-id <NEW_EXTERNAL_ID>
```

This updates both the IAM role and the saved state file.

---

## 7. Script reference

### Setup (Phase 1)

| Item | Description |
|------|-------------|
| Script | `scripts/setup_rh_cost_mgmt.sh` |
| Usage | `./setup_rh_cost_mgmt.sh <BUCKET_NAME> <AWS_REGION> <EXTERNAL_ID> [TAG_REGIONS]` |
| `--wizard` | Interactive prompts for bucket, region, External ID, and optional tagging regions |
| `--plan` | Dry run: print intended actions, no AWS changes |
| `--output json` | Print JSON with `RoleArn`, `ExternalId`, `Bucket`, `Region`, `Prefix` |
| `--show` | Display saved wizard values from state file |
| `-h` / `--help` | Show usage |

### Phase 2 and maintenance

| Item | Description |
|------|-------------|
| `--phase2` | Activate Cost Allocation Tags, validate CUR delivery, check IAM and EC2 tags |
| `--update-external-id <ID>` | Update IAM role trust policy with a new External ID (also updates state file) |

**Examples**

```bash
# Phase 1: Wizard
./scripts/setup_rh_cost_mgmt.sh --wizard

# Phase 1: Direct + EC2 tagging in two regions
./scripts/setup_rh_cost_mgmt.sh rh-cost-mgmt-reports-123456789012-us-east-1 us-east-1 abcdef-1234 us-east-1,us-west-2

# Dry run
./scripts/setup_rh_cost_mgmt.sh rh-bucket us-east-1 abc --plan

# JSON output
./scripts/setup_rh_cost_mgmt.sh rh-bucket us-east-1 abc --output json

# Phase 2: Activate tags and validate (after ~24h)
./scripts/setup_rh_cost_mgmt.sh --phase2

# Update External ID
./scripts/setup_rh_cost_mgmt.sh --update-external-id <NEW_ID>

# Show saved values
./scripts/setup_rh_cost_mgmt.sh --show
```

### Validation

| Item | Description |
|------|-------------|
| Script | `scripts/validate_rh_cost_mgmt.sh` |
| Usage | `./validate_rh_cost_mgmt.sh <BUCKET_NAME> <AWS_REGION> [ROLE_NAME] [EXTERNAL_ID]` |

Checks: bucket/prefix and CUR objects, CUR "koku" definition, Cost Allocation Tags active, IAM role trust (Red Hat principal + External ID) and policy attached.

**Example**

```bash
./scripts/validate_rh_cost_mgmt.sh rh-cost-mgmt-reports-123456789012-us-east-1 us-east-1
```

### Teardown

| Item | Description |
|------|-------------|
| Script | `scripts/teardown_rh_cost_mgmt.sh` |
| Usage | `./teardown_rh_cost_mgmt.sh <BUCKET_NAME> <AWS_REGION> [--remove-bucket] [--yes]` |

Removes the CUR definition and IAM role/policy. With `--remove-bucket`, empties and deletes the bucket. `--yes` skips confirmation.

**Example**

```bash
./scripts/teardown_rh_cost_mgmt.sh rh-cost-mgmt-reports-123456789012-us-east-1 us-east-1 --yes
```

### One-liner installer (when scripts are hosted)

If you host the scripts at a base URL (e.g. CDN or GitHub raw):

```bash
curl -fsSL "<BASE_URL>/install-rh-cost-mgmt.sh" | bash -s -- --base-url "<BASE_URL>" --tool setup -- --wizard
```

Replace `<BASE_URL>` with the URL that serves the scripts and their `.sha256` files. After the second `--`, arguments are passed to the setup script (e.g. `--wizard` or positional args).

- `--tool setup` — run setup (default).
- `--tool validate` — run validation (pass bucket/region after `--`).
- `--tool teardown` — run teardown (pass bucket/region and optional `--yes` after `--`).

The installer downloads the script and its checksum and verifies integrity before running.

---

## 8. Required AWS permissions

The identity used to run the setup script must have:

| Service | Permissions |
|---------|-------------|
| S3 | `s3:CreateBucket`, `s3:PutBucketPolicy`, `s3:Get*`, `s3:List*` (for the CUR bucket/prefix). |
| CUR | `cur:PutReportDefinition`, `cur:DescribeReportDefinitions` (CUR API is in **us-east-1** only). |
| EC2 | `ec2:CreateTags`, `ec2:DescribeInstances` (only if you use TAG_REGIONS). |
| Cost Explorer | `ce:UpdateCostAllocationTagsStatus`, `ce:ListCostAllocationTags`. |
| IAM | Create/update policy and role; attach policy to role. |
| STS | `sts:GetCallerIdentity` (for preflight and account ID). |

---

## 9. Troubleshooting

### "I'm using CloudShell — do I need to configure credentials?"

No. CloudShell is already authenticated with the same identity you used to log into the AWS Console (including Red Hat IdP → role selection). Just run the script there.

### "AWS credentials not configured or lack STS permissions"

- Run: `aws sts get-caller-identity`. If it fails:
  - **SSO:** Run `aws sso login --profile <profile>` then use `AWS_PROFILE=<profile>` when running the script.
  - **No config:** Run `aws configure` or `aws configure sso` and ensure `~/.aws/config` and/or `~/.aws/credentials` exist and are correct.

### "What do I enter for SSO start URL?"

- Use the **AWS** SSO start URL (e.g. `https://d-xxxxxxxxxx.awsapps.com/start`), **not** a Red Hat IdP URL (e.g. `https://auth.redhat.com/.../itaws`). The Red Hat link is for browser SAML; the CLI expects the AWS Identity Center URL. Get the correct SSO start URL from your AWS administrator.

### Finding your AWS CLI profile

- List profiles: `aws configure list-profiles`
- View config: `cat ~/.aws/config`
- Use a profile: `AWS_PROFILE=your-profile-name aws sts get-caller-identity`

### CUR / Cost Explorer in wrong region

- CUR API (`put-report-definition`, `describe-report-definitions`) is only in **us-east-1**. The script uses `us-east-1` for CUR; your bucket can be in another region (e.g. `us-east-1` or `us-west-2`). Cost Allocation Tags are updated in the **region you pass** as `<AWS_REGION>`.

### Cost Allocation Tags not found

- After tagging EC2 instances, it can take **up to 24 hours** for Cost Explorer to discover the tags.
- Run Phase 1 now, wait 24 hours, then run `--phase2` to activate them.
- Do **not** re-run the Red Hat wizard during the wait unless you encounter an error.

### External ID mismatch after re-running Red Hat wizard

- Each time you start a new integration in the Red Hat wizard, it generates a **new External ID**.
- If the External ID in the IAM role doesn't match, Red Hat cannot assume the role.
- Fix with: `./scripts/setup_rh_cost_mgmt.sh --update-external-id <NEW_ID>`

### Script fails on IAM or S3

- Confirm the identity has the [required permissions](#8-required-aws-permissions).
- For bucket names: use a globally unique name; common pattern is `rh-cost-mgmt-reports-<account-id>-<region>`.

---

## 10. After setup

1. **Red Hat Hybrid Cloud Console** — The integration should show as configured once the wizard is completed with the correct Role ARN and External ID.
2. **CUR data** — First CUR delivery can take up to 24 hours. Objects will appear under `s3://<bucket>/cost/`.
3. **Phase 2** — Run `./scripts/setup_rh_cost_mgmt.sh --phase2` after ~24 hours to activate Cost Allocation Tags and validate the full setup.
4. **ELS metering** — Ensure EC2 instances that run RHEL ELS are tagged (by the script if you used TAG_REGIONS, or manually) and that the ELS Marketplace subscription is active.
5. **Show saved values** — Run `./scripts/setup_rh_cost_mgmt.sh --show` anytime to see the wizard values.

---

## Document info

- **Repo:** HCC-cursor-seed  
- **Scripts:** `scripts/setup_rh_cost_mgmt.sh`, `scripts/validate_rh_cost_mgmt.sh`, `scripts/teardown_rh_cost_mgmt.sh`, `scripts/install-rh-cost-mgmt.sh`  
- **State file:** `~/.rh-cost-mgmt-state.json`  
- **More:** See `documentation/aws-rh-cost-mgmt/README.md` in this repo.
