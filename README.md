# EC2 Management via GitHub Actions

Automated AWS EC2 instance management using GitHub Actions workflows over SSH — no AWS CLI, no IAM user credentials, no bastion host required. All operations are driven by GitHub-hosted runners connecting directly to EC2 via a stored SSH key.  || Check On Push .. Main Branch

---

## Table of Contents

1. [What is GitHub Actions?](#what-is-github-actions)
2. [Architecture Overview](#architecture-overview)
3. [Repository Structure](#repository-structure)
4. [Design Decisions](#design-decisions)
5. [Prerequisites](#prerequisites)
6. [Initial Bootstrap — One-Time Setup](#initial-bootstrap--one-time-setup)
   - [Step 0 — Launch an EC2 Instance on AWS](#step-0--launch-an-ec2-instance-on-aws)
   - [Step 0b — Create the GitHub Repository](#step-0b--create-the-github-repository)
   - [Step 1 — Generate an SSH key pair](#step-1--generate-an-ssh-key-pair)
   - [Step 2 — Add the public key to EC2](#step-2--add-the-public-key-to-ec2)
   - [Step 3 — Verify SSH access works manually](#step-3--verify-ssh-access-works-manually)
   - [Step 4 — Clone this repository (do NOT push yet)](#step-4--clone-this-repository-do-not-push-yet)
   - [Step 5 — Configure GitHub Secrets](#step-5--configure-github-secrets)
   - [Step 6 — Deploy metadata.sh to EC2](#step-6--deploy-metadatash-to-ec2)
   - [Step 7 — Push to main and run pipelines in order](#step-7--push-to-main-and-run-pipelines-in-order)
7. [Workflow Reference](#workflow-reference)
   - [EC2 Connectivity Check (Automatic)](#1-ec2-connectivity-check-automatic)
   - [Fix The Hostname (Manual)](#2-fix-the-hostname-manual)
   - [Execute Metadata Script (Manual)](#3-execute-metadata-script-manual)
   - [Deploy Nginx & Dynamic Page (Manual)](#4-deploy-nginx--dynamic-page-manual)
   - [Deploy NGINX to Server B via Self-Hosted Runner (Push)](#5-deploy-nginx-to-server-b-via-self-hosted-runner-push)
8. [Self-Hosted Runner — Deploy to Private EC2 Setup](#self-hosted-runner--deploy-to-private-ec2-setup)
9. [Secrets Management](#secrets-management)
10. [Introducing Changes Safely](#introducing-changes-safely)
11. [Troubleshooting](#troubleshooting)
12. [Security Considerations](#security-considerations)
13. [Reliability Considerations](#reliability-considerations)

---

## What is GitHub Actions?

GitHub Actions is a CI/CD and automation platform built directly into GitHub. Any event in your repository — a push, a pull request, a schedule, or a manual click — can trigger automated workflows that run on cloud-hosted (or self-hosted) machines.

### Core Concepts

| Concept | What it is |
|---|---|
| **Workflow** | A YAML file in `.github/workflows/` — defines what runs and when |
| **Trigger (`on:`)** | The event that starts the workflow: `push`, `pull_request`, `schedule`, `workflow_dispatch`, etc. |
| **Job** | A group of steps that runs on one machine |
| **Step** | A single shell command or a reusable Action |
| **Runner** | The VM that executes the job — GitHub-hosted (`ubuntu-latest`, `windows-latest`, `macos-latest`) or self-hosted |
| **Action** | A pre-built, reusable unit of work (e.g. `actions/checkout@v4`) published to the Marketplace |
| **Secret** | Encrypted variables injected at runtime — never visible in logs |
| **Artifact** | Files saved from a run (build outputs, test reports, generated pages) |

### Key Capabilities

| Area | Examples |
|---|---|
| **CI/CD** | Build, test, and deploy code on every push or PR across any language or framework |
| **Infrastructure automation** | SSH into servers, run Terraform/Ansible, manage AWS/Azure/GCP resources |
| **Security** | Dependency scanning (Dependabot), secret scanning, SAST with CodeQL, OIDC federation for short-lived cloud credentials |
| **Containers** | Build and push Docker images, deploy to ECS/EKS/GKE |
| **Matrix builds** | Test against multiple OS and language versions in parallel with a single `matrix:` config |
| **Reusability** | Reusable workflows, composite actions, and the public Marketplace of 20,000+ community actions |
| **Scheduled tasks** | Cron-syntax `schedule:` trigger — nightly builds, report generation, cleanup jobs |

### How this repository uses it

This repository uses GitHub Actions as a **remote operations platform** for AWS EC2 — replacing manual SSH sessions with audited, repeatable, secrets-safe pipeline runs. Every operation (connectivity check, hostname change, metadata collection, Nginx deployment) is a workflow that leaves a full audit trail in the Actions tab.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        GitHub                               │
│                                                             │
│  ┌──────────────┐     push to main     ┌─────────────────┐  │
│  │  Developer   │ ──────────────────►  │  GitHub Actions │  │
│  │  Workstation │                      │  ubuntu-latest  │  │
│  │              │◄── workflow_dispatch │  Runner         │  │
│  └──────────────┘  (manual trigger)    └────────┬────────┘  │
│                                                 │           │
│  ┌───────────────────────────────┐              │ SSH       │
│  │  Repository Secrets           │              │ (port 22) │
│  │  EC2_SSH_KEY / EC2_HOST       │              │           │
│  │  EC2_USER                     │              │           │
│  └───────────────────────────────┘              │           │
└─────────────────────────────────────────────────┼───────────┘
                                                  │
                                       ┌──────────▼───────────┐
                                       │    AWS EC2 Instance  │
                                       │    (Ubuntu)          │
                                       │                      │
                                       │  /home/ubuntu/       │
                                       │    metadata.sh       │
                                       │                      │
                                       │  IMDSv2 endpoint     │
                                       │  169.254.169.254     │
                                       └──────────────────────┘
```

**Data flow:**
1. A `git push` to `main` (or a manual dispatch) triggers a GitHub Actions runner.
2. The runner writes the SSH private key from `EC2_SSH_KEY` secret to a temporary file (`~/.ssh/ec2_key`, mode `600`).
3. The runner uses `ssh-keyscan` to pre-populate `known_hosts`, avoiding interactive host-key prompts.
4. The runner SSHs into EC2 and executes commands remotely.
5. EC2 fetches its own metadata through the Instance Metadata Service v2 (IMDSv2) — an HTTP endpoint available only from within the instance.
6. All SSH keys are removed from runner disk at the end of each job.

---

## Repository Structure

```
.
├── .github/
│   └── workflows/
│       ├── ec2-connectivity-check.yml   # Auto-runs on every push to main
│       ├── fix-hostname.yml             # Manual — sets EC2 hostname to "HelloWorld"
│       ├── execute-metadata-script.yml  # Manual — runs metadata.sh on EC2
│       ├── deploy-nginx.yml             # Manual — installs Nginx, deploys live dashboard
│       └── deploy.yaml                  # Auto on push — self-hosted runner deploys to private Server B
├── metadata.sh                          # Bash script deployed to EC2; collects instance metadata
├── .gitignore                           # Excludes SSH keys, .env files, OS junk
└── README.md                            # This file
```

---

## Design Decisions

| Decision | Rationale |
|---|---|
| **GitHub-hosted runners (`ubuntu-latest`)** | Zero infrastructure maintenance; runner is ephemeral and discarded after each job — no persistent credentials on a server. |
| **SSH key stored as a GitHub Secret** | Avoids embedding credentials in code. Secret is never printed in logs; GitHub masks it automatically. |
| **IMDSv2 (token-based metadata)** | IMDSv1 (no token) is a known attack vector (SSRF target). IMDSv2 requires a PUT request to obtain a short-lived token, preventing those attacks. |
| **`ssh-keyscan` for host verification** | Eliminates the `StrictHostKeyChecking=no` anti-pattern, which silently accepts man-in-the-middle attacks. |
| **Idempotent hostname workflow** | Checks the current hostname before attempting a change. Running the workflow twice on an already-correct host is safe and produces no side effects. |
| **`set -euo pipefail` in `metadata.sh`** | Any unhandled error, unset variable, or broken pipe exits immediately with a non-zero code rather than silently continuing. |
| **`workflow_dispatch` for operational workflows** | Hostname fixing and script execution are intentional, destructive-enough operations — they should never run automatically on a code push. |

---

## Prerequisites

### Local machine

| Tool | Minimum version | Purpose |
|---|---|---|
| Git | 2.x | Clone repository, push changes |
| SSH client | OpenSSH 7.x+ | Generate key pair, manual EC2 access |
| AWS Account | — | EC2 instance to target |

### AWS EC2 instance

| Requirement | Detail |
|---|---|
| OS | Ubuntu 20.04 LTS or later (workflows assume `ubuntu` user) |
| Inbound Security Group — SSH | TCP port **22** open to `0.0.0.0/0` **or** to [GitHub Actions IP ranges](https://api.github.com/meta) |
| Inbound Security Group — HTTP | TCP port **80** open to `0.0.0.0/0` (required for `deploy-nginx.yml` to serve the page) |
| IMDSv2 | Must be enabled (default on instances launched after Nov 2019) |
| `curl` | Pre-installed on all Ubuntu AMIs |
| `hostnamectl` | Pre-installed via `systemd` on Ubuntu |

### GitHub

- A GitHub repository with Actions enabled (Settings → Actions → Allow all actions).

---

## Initial Bootstrap — One-Time Setup

### Step 0 — Launch an EC2 Instance on AWS

If you do not have an EC2 instance yet, follow these steps in the AWS Console:

1. Go to **AWS Console → EC2 → Instances → Launch instances**
2. Configure the instance:

   | Setting | Recommended value |
   |---|---|
   | Name | `github-actions-target` (or any name) |
   | AMI | **Ubuntu Server 22.04 LTS** (Free tier eligible) |
   | Instance type | `t2.micro` (Free tier) or larger |
   | Key pair | Create a new key pair → type **ED25519** → download the `.pem` file to a safe location |
   | Network | Default VPC is fine |
   | Security group | Create new → add inbound rule: **SSH / TCP / port 22 / Source: `0.0.0.0/0`** |

3. Click **Launch instance** and wait ~1 minute for the instance to reach **Running** state.
4. In the instance list, note down the **Public IPv4 address** — you will need it throughout this guide as `<EC2_PUBLIC_IP>`.
5. Fix the permissions on your downloaded key pair:

   ```bash
   chmod 400 /path/to/your-downloaded-key.pem
   ```

6. Test that the instance is reachable:

   ```bash
   ssh -i /path/to/your-downloaded-key.pem ubuntu@<EC2_PUBLIC_IP> "echo connected"
   ```

   You should see `connected` printed. If this fails, check that the Security Group has port 22 open and the instance is in **Running** state.

> **IMDSv2 note:** All Ubuntu AMIs launched from the AWS Console after November 2019 have IMDSv2 available by default. No extra configuration is needed.

---

### Step 0b — Create the GitHub Repository

If you do not have a GitHub repository yet:

1. Go to [github.com](https://github.com) and sign in.
2. Click **+** (top right) → **New repository**.
3. Fill in:
   - **Repository name:** `github-actions-hello-world`
   - **Visibility:** Public or Private (both work)
   - **Do NOT** tick "Add a README", ".gitignore", or "license" — the repo must be empty.
4. Click **Create repository**.
5. Copy the repository URL shown (e.g. `https://github.com/<YOUR_USERNAME>/github-actions-hello-world.git`).

---

### Step 1 — Generate an SSH key pair

Run this on your local machine. **Do not use an existing key shared with other systems.**

```bash
ssh-keygen -t ed25519 -C "github-actions-ec2" -f ~/.ssh/github_actions_ec2 -N ""
```

This creates:
- `~/.ssh/github_actions_ec2`      — **private key** → goes into GitHub Secrets
- `~/.ssh/github_actions_ec2.pub`  — **public key**  → goes onto EC2

### Step 2 — Add the public key to EC2

```bash
# Replace <EC2_PUBLIC_IP> and <PATH_TO_YOUR_EXISTING_KEY> with your values
ssh -i <PATH_TO_YOUR_EXISTING_KEY> ubuntu@<EC2_PUBLIC_IP> \
  "echo '$(cat ~/.ssh/github_actions_ec2.pub)' >> ~/.ssh/authorized_keys"
```

Or if you already have console/SSM access, paste the public key content directly into `~/.ssh/authorized_keys` on the instance.

### Step 3 — Verify SSH access works manually

```bash
ssh -i ~/.ssh/github_actions_ec2 ubuntu@<EC2_PUBLIC_IP> "hostname"
```

You should see the current hostname printed. If this fails, do **not** proceed — fix connectivity first (Security Group rules, instance state, etc.).

### Step 4 — Clone this repository (do NOT push yet)

```bash
git clone https://github.com/<YOUR_USERNAME>/github-actions-hello-world.git
cd github-actions-hello-world
```

> **Do NOT push to main yet.** A push to `main` automatically triggers the EC2 Connectivity Check pipeline. That pipeline requires the secrets in Step 5 to be in place first — push before that and it will fail immediately.

---

### Step 5 — Configure GitHub Secrets

All three secrets are **required**. Workflows will fail immediately if any is missing.

Navigate to: **GitHub repo → Settings → Secrets and variables → Actions → New repository secret**

| Secret name | Value | Example |
|---|---|---|
| `EC2_SSH_KEY` | Full content of the **private key** file (including header/footer lines) | `-----BEGIN OPENSSH PRIVATE KEY-----`...`-----END OPENSSH PRIVATE KEY-----` |
| `EC2_HOST` | Public IP address or DNS hostname of the EC2 instance | `54.123.45.67` or `ec2-54-123-45-67.compute-1.amazonaws.com` |
| `EC2_USER` | SSH username on the instance | `ubuntu` (default for Ubuntu AMIs) |

**How to copy the private key value:**

```bash
cat ~/.ssh/github_actions_ec2
# Copy the entire output — header, body, and footer lines
```

> **Note:** If your EC2 instance is assigned an Elastic IP, use that address. If it uses a dynamic public IP, update `EC2_HOST` every time the instance is stopped and restarted.

---

### Step 6 — Deploy metadata.sh to EC2

The [execute-metadata-script.yml](.github/workflows/execute-metadata-script.yml) pipeline expects `metadata.sh` to already exist at `/home/ubuntu/metadata.sh` on the EC2 instance. Deploy it once now:

```bash
scp -i ~/.ssh/github_actions_ec2 metadata.sh ubuntu@<EC2_PUBLIC_IP>:/home/ubuntu/metadata.sh
```

The workflow will `chmod +x` it automatically if needed. You do not need to set execute permissions manually.

---

### Step 7 — Push to main and run pipelines in order

Now that EC2 is running, secrets are configured, and `metadata.sh` is deployed — you are ready. Run the three pipelines in this order:

#### Pipeline 1 — EC2 Connectivity Check (automatic)

Push to `main`. This triggers the pipeline automatically:

```bash
git add .
git commit -m "initial: EC2 management workflows"
git push origin main
```

Go to **GitHub → Actions tab** and watch the **EC2 Connectivity Check** run. It will:
- Verify SSH connection to your EC2 instance
- Print hostname, IPs, instance ID, availability zone, instance type, and uptime

✅ **Expected result:** Green check. If it fails, see [Troubleshooting](#troubleshooting) before continuing.

---

#### Pipeline 2 — Fix The Hostname (manual)

Once Pipeline 1 passes:

1. Go to **GitHub → Actions tab**
2. Click **Fix The Hostname** in the left sidebar
3. Click **Run workflow** → select branch `main` → click the green **Run workflow** button

It will:
- Check the current hostname on EC2
- Change it to `HelloWorld` if it is not already set
- Verify the change took effect
- Skip silently if already correct

✅ **Expected result:** Green check. The hostname on your EC2 instance is now `HelloWorld`.

---

#### Pipeline 3 — Execute Metadata Script (manual)

Once Pipeline 2 passes:

1. Go to **GitHub → Actions tab**
2. Click **Execute Metadata Script** in the left sidebar
3. Click **Run workflow** → select branch `main` → click the green **Run workflow** button

It will:
- Confirm `metadata.sh` exists at `/home/ubuntu/metadata.sh`
- Execute it on EC2 and stream the full output into the Actions log
- Display instance ID, type, AMI, IPs, region, AZ, IAM role, block devices, and tags

✅ **Expected result:** Green check with full metadata output printed in the job log.

---

#### Pipeline 4 — Deploy Nginx & Dynamic Page (manual)

Once Pipeline 3 passes:

> **Before running:** Ensure TCP port 80 is open inbound in the EC2 Security Group.

1. Go to **GitHub → Actions tab**
2. Click **Deploy Nginx & Dynamic Page** in the left sidebar
3. Click **Run workflow** → select branch `main` → click the green **Run workflow** button

It will:
- Install Nginx on the EC2 instance (if not already installed)
- Collect all live metadata from the instance (hostname, IPs, instance details, uptime, etc.)
- Generate a fully dynamic `index.html` with that real data
- Deploy it to `/var/www/html/index.html` and reload Nginx
- Verify the page returns HTTP 200 from port 80

✅ **Expected result:** Green check. Open a browser and navigate to:
```
http://<EC2_PUBLIC_IP>
```
You will see the live dashboard with your server's real hostname, IP addresses, instance details, and deployment timestamp.

---

## Workflow Reference

### 1. EC2 Connectivity Check (Automatic)

| Property | Value |
|---|---|
| **File** | `.github/workflows/ec2-connectivity-check.yml` |
| **Trigger** | Automatic — every `push` to `main` branch |
| **Runner** | `ubuntu-latest` (GitHub-hosted) |
| **Idempotent** | Yes — read-only, no changes made to EC2 |

**What it does, step by step:**

| Step | Description |
|---|---|
| Checkout Repository | Checks out the repository onto the runner (`actions/checkout@v4`) |
| Setup SSH Key | Writes `EC2_SSH_KEY` secret to `~/.ssh/ec2_key` with mode `600`; adds host key via `ssh-keyscan` |
| Test EC2 Connectivity | Runs `echo 'SSH connection successful!'` on EC2 with a 10-second connection timeout |
| Extract EC2 Metadata | SSHes into EC2 and queries IMDSv2 for: hostname, public IP, private IP, instance ID, availability zone, instance type, and system uptime |
| Cleanup SSH Key | Removes `~/.ssh/ec2_key` from the runner — runs unconditionally (`if: always()`) even if earlier steps fail |

**When it fails:**
- SSH connection refused → Security Group or instance not running
- `ConnectTimeout` → Wrong `EC2_HOST` or network unreachable
- Secrets missing → Workflow exits at the SSH setup step

---

### 2. Fix The Hostname (Manual)

| Property | Value |
|---|---|
| **File** | `.github/workflows/fix-hostname.yml` |
| **Trigger** | Manual — **Actions tab → Fix The Hostname → Run workflow** |
| **Runner** | `ubuntu-latest` (GitHub-hosted) |
| **Idempotent** | Yes — skips all changes if hostname is already `HelloWorld` |

**What it does, step by step:**

| Step | Description |
|---|---|
| Checkout Repository | Checks out the repository onto the runner (`actions/checkout@v4`) |
| Setup SSH Key | Writes `EC2_SSH_KEY` secret to `~/.ssh/ec2_key` with mode `600`; adds host key via `ssh-keyscan` |
| Check Current Hostname | Reads current hostname; sets `needs_change` output to `true` or `false` |
| Set Hostname to HelloWorld | Runs only if `needs_change == true`; uses `hostnamectl set-hostname` (immediate), writes `/etc/hostname` (persistence), and patches `/etc/hosts` |
| Verify Hostname Change | Re-reads hostname after change; exits with code `1` if verification fails |
| Hostname Already Correct | Informational step shown when no change was needed |
| Cleanup SSH Key | Removes `~/.ssh/ec2_key` from the runner — runs unconditionally (`if: always()`) even if earlier steps fail |

**Files modified on EC2:**

```
/etc/hostname          # Updated to "HelloWorld"
/etc/hosts             # 127.0.1.1 entry updated to "HelloWorld"
```

---

### 3. Execute Metadata Script (Manual)

| Property | Value |
|---|---|
| **File** | `.github/workflows/execute-metadata-script.yml` |
| **Trigger** | Manual — **Actions tab → Execute Metadata Script → Run workflow** |
| **Runner** | `ubuntu-latest` (GitHub-hosted) |
| **Idempotent** | Yes — read-only script execution |
| **Dependency** | `metadata.sh` must exist at `/home/ubuntu/metadata.sh` on EC2 |

**What it does, step by step:**

| Step | Description |
|---|---|
| Checkout Repository | Checks out the repository onto the runner (`actions/checkout@v4`) |
| Setup SSH Key | Writes `EC2_SSH_KEY` secret to `~/.ssh/ec2_key` with mode `600`; adds host key via `ssh-keyscan` |
| Check if metadata.sh exists | SSHes and runs `test -f /home/ubuntu/metadata.sh`; sets `file_exists` output to `true` or `false` |
| Execute metadata.sh script | Runs only if `file_exists == true`; auto-applies `chmod +x` if not executable; executes `/home/ubuntu/metadata.sh` |
| File Not Found | Runs if `file_exists == false`; prints remediation instructions and exits with code `1` |
| Cleanup SSH Key | Removes `~/.ssh/ec2_key` from the runner — runs unconditionally (`if: always()`) even if earlier steps fail |

**Output collected by `metadata.sh`:**

| Category | Fields |
|---|---|
| Instance | ID, type, AMI ID, hostname, local hostname |
| Network | Private IP, public IP, MAC address |
| Location | Availability zone, region |
| IAM | Attached IAM role name and credentials (if role present) |
| Storage | Block device mappings |
| Tags | Instance tags (requires tag access enabled on instance) |

---

### 4. Deploy Nginx & Dynamic Page (Manual)

| Property | Value |
|---|---|
| **File** | `.github/workflows/deploy-nginx.yml` |
| **Trigger** | Manual — **Actions tab → Deploy Nginx & Dynamic Page → Run workflow** |
| **Runner** | `ubuntu-latest` (GitHub-hosted) |
| **Idempotent** | Yes — re-running overwrites the page with fresh data; Nginx install is skipped if already present |
| **Prerequisite** | Security Group must allow **TCP port 80** inbound |

**What it does, step by step:**

| Step | Description |
|---|---|
| Checkout Repository | Checks out the repository onto the runner (`actions/checkout@v4`) |
| Setup SSH Key | Writes `EC2_SSH_KEY` secret to `~/.ssh/ec2_key` with mode `600`; adds host key via `ssh-keyscan` |
| Install Nginx on EC2 | SSHes into EC2; runs `apt-get install nginx`; enables and starts the service; idempotent |
| Generate Dynamic Page & Deploy | Passes GitHub context variables (`workflow`, `run_number`, `actor`, `repository`) to EC2 via `bash -s --`; EC2 fetches its own hostname, IPs, instance ID, type, AZ, region, AMI, uptime, OS, and Nginx version via IMDSv2; generates a fully dynamic `index.html` and copies it to `/var/www/html/index.html`; reloads Nginx |
| Verify Site is Reachable on Port 80 | Runner curls `http://<EC2_HOST>` and checks for HTTP 200; prints the URL on success or Security Group instructions on failure |
| Cleanup SSH Key | Removes `~/.ssh/ec2_key` from the runner — runs unconditionally (`if: always()`) |

**Dynamic fields rendered on the live page:**

| Field | Source |
|---|---|
| Server Online status | Always shown (Nginx is running at deploy time) |
| Hostname | `hostname` command on EC2 |
| Pipeline name | `${{ github.workflow }}` — passed from runner |
| Runner | Hardcoded `ubuntu-latest` — matches the workflow `runs-on` |
| Auth Method | Hardcoded `SSH / ED25519` |
| Metadata Service | IMDSv2 token check — shows `IMDSv2 Active` or `Unavailable` |
| Public IP | IMDSv2 `public-ipv4` |
| Private IP | IMDSv2 `local-ipv4` |
| Instance ID | IMDSv2 `instance-id` |
| Instance Type | IMDSv2 `instance-type` |
| Availability Zone | IMDSv2 `placement/availability-zone` |
| Region | IMDSv2 `placement/region` |
| AMI ID | IMDSv2 `ami-id` |
| Uptime | `uptime -p` on EC2 |
| OS | `lsb_release -ds` on EC2 |
| Web Server | `nginx -v` on EC2 |
| Last deployed / Run number | `date -u` + `${{ github.run_number }}` |

**Browse the live page:**
```
http://<EC2_PUBLIC_IP>
```

> **Port 80 not open?** AWS Console → EC2 → Security Groups → select your instance's security group → Inbound rules → Add rule: Type = HTTP, Protocol = TCP, Port = 80, Source = `0.0.0.0/0`.

---

## Secrets Management

### Rotating the SSH key

When rotating the SSH key (recommended every 90 days or if key exposure is suspected):

```bash
# 1. Generate new key pair
ssh-keygen -t ed25519 -C "github-actions-ec2-rotated" -f ~/.ssh/github_actions_ec2_new -N ""

# 2. Add new public key to EC2 BEFORE removing the old one
ssh -i ~/.ssh/github_actions_ec2 ubuntu@<EC2_PUBLIC_IP> \
  "echo '$(cat ~/.ssh/github_actions_ec2_new.pub)' >> ~/.ssh/authorized_keys"

# 3. Update EC2_SSH_KEY secret in GitHub with contents of the new private key
#    (GitHub → Settings → Secrets and variables → Actions → EC2_SSH_KEY → Update)

# 4. Verify the new key works by triggering EC2 Connectivity Check

# 5. Remove the old public key from EC2 authorized_keys
ssh -i ~/.ssh/github_actions_ec2_new ubuntu@<EC2_PUBLIC_IP> \
  "sed -i '/github-actions-ec2$/d' ~/.ssh/authorized_keys"
```

### Updating the EC2 host address

If your instance's public IP changes (e.g., after a stop/start):

1. Go to **GitHub → Settings → Secrets and variables → Actions**
2. Click the pencil icon next to `EC2_HOST`
3. Enter the new IP address and save
4. Trigger **EC2 Connectivity Check** to confirm

---

## Introducing Changes Safely

### Before editing any workflow file

1. **Read the affected workflow end-to-end** — understand every step and its conditionals.
2. **Check which secrets are referenced** — a renamed secret will silently be `""` at runtime, failing the job.
3. **Test in a feature branch first.** The push-triggered workflow only fires on `main`. Manual workflows can be dispatched from any branch.

### Branching strategy

```bash
git checkout -b feature/my-change
# make edits
git push origin feature/my-change
# Trigger manual workflows from this branch via the Actions tab (select branch in dropdown)
# Only merge to main after validating
```

### Adding a new workflow

- Keep one job per workflow for clarity. Split into multiple jobs only when steps are genuinely parallel.
- Always include a **Cleanup SSH Key** step using `if: always()` so credentials are removed even when earlier steps fail:

```yaml
- name: Cleanup SSH Key
  if: always()
  run: rm -f ~/.ssh/ec2_key
```

- Use `actions/checkout@v4` — pin to a major version tag, not `latest`, to avoid unexpected breaking changes from upstream action updates.

### Editing `metadata.sh`

After editing `metadata.sh` locally, re-deploy to EC2 before running the workflow:

```bash
scp -i ~/.ssh/github_actions_ec2 metadata.sh ubuntu@<EC2_PUBLIC_IP>:/home/ubuntu/metadata.sh
```

Then trigger **Execute Metadata Script** to validate the output.

---

## Troubleshooting

### `Permission denied (publickey)`

- The public key corresponding to `EC2_SSH_KEY` is not in `~/.ssh/authorized_keys` on EC2.
- Verify with: `cat ~/.ssh/authorized_keys` on the instance (via AWS console Session Manager or existing access).
- Ensure the secret value includes the full key including `-----BEGIN` and `-----END` lines.

### `ssh-keyscan` produces empty output

- EC2 instance is stopped or the IP has changed.
- Security Group does not allow inbound TCP 22 from the runner's IP.
- Check the instance state in the AWS Console.

### Hostname not persisting after instance reboot

- The workflow patches both `/etc/hostname` and `/etc/hosts`. If the instance uses cloud-init, the hostname may be reset on reboot by the cloud-init `set_hostname` module.
- To prevent this, disable the cloud-init hostname module on EC2:

```bash
echo "preserve_hostname: true" | sudo tee -a /etc/cloud/cloud.cfg
```

### `metadata.sh` — `Failed to retrieve IMDSv2 token`

- IMDSv2 is not accessible. This happens when `metadata.sh` is run outside an EC2 instance (e.g., locally). The script **must** run on the EC2 instance itself.
- If the instance has IMDSv2 set to `required` with a hop limit of `1`, ensure no proxy is intercepting the metadata request.

### Workflow queued but never starts

- GitHub Actions may be paused at the repository or organisation level.
- Check: **Settings → Actions → General → Actions permissions**.

---

## Security Considerations

| Area | Control |
|---|---|
| SSH private key | Stored exclusively as a GitHub encrypted secret; never committed to the repository (`.gitignore` excludes `*.key`, `*.pem`) |
| Host key verification | `ssh-keyscan` pre-populates `known_hosts`; `StrictHostKeyChecking` remains at its default (`yes`) — runner will refuse unknown hosts |
| IMDSv2 | All metadata requests use a short-lived token (6-hour TTL) obtained via PUT — resistant to SSRF attacks |
| Key scope | The deploy key grants access only to this EC2 instance — do not reuse it across other systems |
| Principle of least privilege | The `ubuntu` user should not have unrestricted `sudo`. If `hostnamectl` requires sudo, scope it via `/etc/sudoers.d/` rather than granting full sudo |
| Secret rotation | Rotate `EC2_SSH_KEY` on a regular schedule and immediately upon suspected exposure |
| Runner isolation | GitHub-hosted runners are ephemeral VMs destroyed after each job — no state or credentials persist between runs |

---

## Reliability Considerations

| Area | Detail |
|---|---|
| SSH `ConnectTimeout=10` | The connectivity check fails fast (10 s) rather than hanging the runner for the default 120 s TCP timeout |
| `set -euo pipefail` in `metadata.sh` | Any error aborts execution immediately with a non-zero exit code, which propagates as a workflow failure |
| Conditional steps (`if:`) | The hostname and file-check workflows use output variables to skip steps that are not needed, preventing no-op commands from introducing errors |
| Verification step | After setting the hostname, a dedicated verify step re-reads the value and explicitly fails (`exit 1`) if it does not match — no silent failures |
| Action version pinning | Workflows use `actions/checkout@v4` with a major version pin — receives patch/minor updates automatically while avoiding breaking major-version changes |
| Key cleanup | All workflows remove `~/.ssh/ec2_key` at the end of the job, including if earlier steps fail (use `if: always()` when adding new cleanup steps) |

---

### 5. Deploy NGINX to Server B via Self-Hosted Runner (Push)

| Property | Value |
|---|---|
| **File** | `.github/workflows/deploy.yaml` |
| **Trigger** | Automatic — every `push` to `main` branch; also `workflow_dispatch` |
| **Runner** | `self-hosted` — Server A (public subnet EC2, registered as GitHub Actions runner) |
| **Idempotent** | Yes — NGINX install skipped if already present; page always overwritten with latest |
| **Prerequisites** | Server A registered as self-hosted runner; `SERVER_B_SSH_KEY`, `SERVER_B_HOST`, `SERVER_B_USER` secrets set; port 80 open from Server A → Server B |

**What it does, step by step:**

| Step | Description |
|---|---|
| Checkout Repository | Checks out the repository onto Server A (`actions/checkout@v4`) |
| Setup SSH Key | Writes `SERVER_B_SSH_KEY` to `~/.ssh/server_b_key` (mode `600`); pre-populates `known_hosts` via `ssh-keyscan` |
| Verify SSH Connectivity | SSH probe from Server A → Server B with `ConnectTimeout=10`; prints hostname and private IP |
| Upload index.html | `scp` copies `index.html` from repo to `/tmp/index.html` on Server B |
| Install NGINX & Deploy Page | SSH into Server B: idempotent NGINX install → copy page to `/var/www/html/index.html` → reload or start NGINX |
| Health Check | `curl` from Server A to `http://SERVER_B_HOST` — fails the job if response is not HTTP 200 |
| Deployment Summary | Logs repo, branch, commit SHA, actor, run number, and target host |
| Cleanup SSH Key | Removes `~/.ssh/server_b_key` from Server A — runs unconditionally (`if: always()`) |

---

## Self-Hosted Runner — Deploy to Private EC2 Setup

This section covers the complete one-time setup required to run `deploy.yaml`.

### Infrastructure Overview

```
  GitHub ──push──► GitHub Actions
                        │
                        │ dispatches job to
                        ▼
              ┌─────────────────────┐
              │  Server A (Runner)  │  Public subnet, internet access
              │  self-hosted runner │  SSH key to Server B
              └────────┬────────────┘
                       │ SSH (port 22, private IP)
                       ▼
              ┌─────────────────────┐
              │  Server B (Target)  │  Private subnet, no public IP
              │  NGINX on port 80   │
              └────────┬────────────┘
                       │ port 80
                       ▼
              ┌─────────────────────┐
              │  AWS ALB (HTTPS)    │  ACM certificate, public
              └─────────────────────┘
```

### Step 1 — Register Server A as a Self-Hosted Runner

1. Go to **GitHub repo → Settings → Actions → Runners → New self-hosted runner**
2. Select **Linux** and follow the displayed commands on Server A:

```bash
# On Server A — download and configure the runner
mkdir actions-runner && cd actions-runner
curl -o actions-runner-linux-x64.tar.gz -L \
  https://github.com/actions/runner/releases/latest/download/actions-runner-linux-x64.tar.gz
tar xzf actions-runner-linux-x64.tar.gz
./config.sh --url https://github.com/<YOUR_USERNAME>/<YOUR_REPO> --token <TOKEN_FROM_GITHUB>
```

3. Install and start as a system service so it survives reboots:

```bash
sudo ./svc.sh install
sudo ./svc.sh start
sudo ./svc.sh status   # should show: active (running)
```

### Step 2 — Generate SSH key for Server A → Server B

Run this **on Server A**:

```bash
ssh-keygen -t ed25519 -C "github-actions-server-b" -f ~/.ssh/server_b_deploy -N ""
```

Copy the public key to Server B:

```bash
ssh-copy-id -i ~/.ssh/server_b_deploy.pub ubuntu@<SERVER_B_PRIVATE_IP>
# or manually:
ssh ubuntu@<SERVER_B_PRIVATE_IP> "echo '$(cat ~/.ssh/server_b_deploy.pub)' >> ~/.ssh/authorized_keys"
```

Verify it works:

```bash
ssh -i ~/.ssh/server_b_deploy ubuntu@<SERVER_B_PRIVATE_IP> "hostname"
```

### Step 3 — Add GitHub Secrets

Navigate to: **GitHub repo → Settings → Secrets and variables → Actions → New repository secret**

| Secret | Value |
|---|---|
| `SERVER_B_SSH_KEY` | Full content of `~/.ssh/server_b_deploy` (private key, including `-----BEGIN` and `-----END` lines) |
| `SERVER_B_HOST` | Private IP of Server B — e.g. `10.0.1.50` |
| `SERVER_B_USER` | SSH user on Server B — `ubuntu` |

**Copy the private key value on Server A:**

```bash
cat ~/.ssh/server_b_deploy
# Copy entire output including header and footer lines
```

### Step 4 — Security Group Rules

| Rule | Direction | Source | Destination | Port |
|---|---|---|---|---|
| SSH | Inbound on Server B | Server A security group ID | Server B | 22 |
| HTTP | Inbound on Server B | ALB security group ID | Server B | 80 |
| HTTPS | Inbound on ALB | `0.0.0.0/0` | ALB | 443 |
| All outbound | Outbound on Server B | Server B | `0.0.0.0/0` | All (for `apt-get`) |

### Step 5 — Push and verify

```bash
git add .
git commit -m "add: self-hosted NGINX deploy pipeline"
git push origin main
```

Go to **GitHub → Actions tab → Deploy NGINX to Server B** and watch the run. All 8 steps should go green. The health check will confirm NGINX is serving HTTP 200 on Server B's private IP.

Once the pipeline is green, your ALB (pointed at Server B port 80) will serve the page publicly over HTTPS.

---

## 🧑‍💻 Author

*Md. Sarowar Alam*  
Lead DevOps Engineer, Hogarth Worldwide  
📧 Email: sarowar@hotmail.com  
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/
