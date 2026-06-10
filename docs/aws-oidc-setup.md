# Configuring AWS Authentication via OIDC for GitHub Actions

## What is OIDC and Why Use It?

GitHub Actions supports **OpenID Connect (OIDC)** — a standard that lets your workflow
prove its identity to AWS without storing any long-lived credentials (Access Key ID /
Secret Access Key) anywhere.

### Traditional approach (Access Keys) — problems

```
Developer  →  generates AWS Access Key + Secret Key
           →  pastes them into GitHub Secrets
           →  they sit there forever, never rotating
           →  if leaked → attacker has permanent AWS access
```

### OIDC approach — how it works

```
GitHub Actions Runner
  │
  ├─ 1. Requests a short-lived OIDC JWT token from GitHub's token endpoint
  │      Token contains claims: repo name, branch, workflow, actor, etc.
  │
  ├─ 2. Sends that JWT to AWS STS → AssumeRoleWithWebIdentity
  │
  ├─ 3. AWS validates the JWT signature against GitHub's public keys
  │      AND checks your trust policy conditions (repo, branch, etc.)
  │
  └─ 4. AWS returns temporary credentials (valid ~1 hour, auto-expire)
         Access Key + Secret Key + Session Token — used for that run only
```

**Key benefit:** No static credentials exist anywhere. Nothing to rotate, nothing to leak.

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                          GitHub                                 │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Workflow Job (ubuntu-latest runner)                     │   │
│  │                                                          │   │
│  │  permissions:                                            │   │
│  │    id-token: write  ◄── enables OIDC token request       │   │
│  │    contents: read                                        │   │
│  │                                                          │   │
│  │  uses: aws-actions/configure-aws-credentials@v4          │   │
│  │    role-to-assume: arn:aws:iam::123:role/MyRole          │   │
│  └──────────────────┬───────────────────────────────────────┘   │
│                     │  1. Request OIDC JWT                      │
│  ┌──────────────────▼───────────────┐                           │
│  │  GitHub OIDC Token Endpoint      │                           │
│  │  token.actions.githubusercontent.com                         │
│  │                                  │                           │
│  │  Issues JWT containing:          │                           │
│  │  - iss: token.actions...         │                           │
│  │  - sub: repo:owner/repo:ref:...  │                           │
│  │  - aud: sts.amazonaws.com        │                           │
│  └──────────────────┬───────────────┘                           │
└─────────────────────┼───────────────────────────────────────────┘
                      │  2. AssumeRoleWithWebIdentity (JWT)
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                          AWS                                    │
│                                                                 │
│  ┌───────────────────────────────┐                              │
│  │  IAM OIDC Identity Provider   │                              │
│  │  URL: token.actions...        │◄── validates JWT signature   │
│  │  Audience: sts.amazonaws.com  │    using GitHub's JWKS       │
│  └───────────────┬───────────────┘                              │
│                  │  3. Trust Policy check                       │
│  ┌───────────────▼───────────────┐                              │
│  │  IAM Role: GitHubActions-Role │                              │
│  │  Trust Policy conditions:     │                              │
│  │  - sub matches repo name      │                              │
│  │  - aud = sts.amazonaws.com    │                              │
│  └───────────────┬───────────────┘                              │
│                  │  4. Returns temp credentials (~1 hour)       │
│  ┌───────────────▼───────────────┐                              │
│  │  AWS STS                      │                              │
│  │  AccessKeyId (temp)           │                              │
│  │  SecretAccessKey (temp)       │                              │
│  │  SessionToken (temp)          │                              │
│  └───────────────────────────────┘                              │
└─────────────────────────────────────────────────────────────────┘
```

---

## Step-by-Step AWS Setup

### Step 1 — Create the OIDC Identity Provider

1. Open **AWS Console** → **IAM** → **Identity providers** → **Add provider**
2. Choose **OpenID Connect**
3. Fill in:

   | Field | Value |
   |---|---|
   | Provider URL | `https://token.actions.githubusercontent.com` |
   | Audience | `sts.amazonaws.com` |

4. Click **Get thumbprint** → then **Add provider**

> **Why this step?** This tells AWS: "I trust JWTs signed by GitHub's token service."
> AWS uses GitHub's public keys (fetched via JWKS) to verify any incoming JWT is genuine.

---

### Step 2 — Create the IAM Role

1. **IAM** → **Roles** → **Create role**
2. **Trusted entity type**: Web identity
3. **Identity provider**: select `token.actions.githubusercontent.com`
4. **Audience**: `sts.amazonaws.com`

#### Trust Policy (fine-tune after creation)

The auto-generated trust policy will look like this — edit it to restrict to **your specific repository**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:<YOUR_GITHUB_USERNAME>/<YOUR_REPO>:ref:refs/heads/main"
        }
      }
    }
  ]
}
```

> **`sub` claim** is the key security control. Without scoping it to your repo,
> **any** GitHub Actions workflow on any repo could assume your role.

Common `sub` patterns:

| Scope | `sub` value |
|---|---|
| Specific branch (`main`) | `repo:owner/repo:ref:refs/heads/main` |
| Any branch in the repo | `repo:owner/repo:*` |
| Only `workflow_dispatch` triggers | `repo:owner/repo:ref:refs/heads/main` + add `token.actions.githubusercontent.com:job_workflow_ref` condition |
| Specific environment | `repo:owner/repo:environment:production` |

#### Permissions Policy

Attach a permissions policy that allows the workflow to do what it needs.
For the EC2 provisioning workflow in this repo:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2Provision",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeImages",
        "ec2:DescribeSecurityGroups",
        "ec2:CreateSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RunInstances",
        "ec2:DescribeInstances",
        "ec2:CreateTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassInstanceProfile",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/<INSTANCE_PROFILE_ROLE_NAME>"
    }
  ]
}
```

> **Why `iam:PassRole`?** When you attach an IAM Instance Profile to an EC2 instance
> (`aws ec2 run-instances --iam-instance-profile`), AWS checks that the calling identity
> has permission to *pass* that role to the EC2 service. Without it, the call is denied
> even if you have `ec2:RunInstances`.

5. **Role name**: e.g. `GitHubActions-EC2-Role`
6. Copy the **Role ARN** — looks like: `arn:aws:iam::123456789012:role/GitHubActions-EC2-Role`

---

### Step 3 — Store the Role ARN as a GitHub Secret

1. GitHub repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**
2. Name: `AWS_ROLE_ARN`
3. Value: `arn:aws:iam::<ACCOUNT_ID>:role/GitHubActions-EC2-Role`

---

## How It Looks in the Workflow

```yaml
# These two permissions are mandatory for OIDC to work.
# id-token: write  → allows the runner to request a JWT from GitHub
# contents: read   → allows actions/checkout (standard)
permissions:
  id-token: write
  contents: read

steps:
  - name: Configure AWS Credentials (OIDC)
    uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
      aws-region: ap-south-1
```

### What `aws-actions/configure-aws-credentials@v4` does internally

1. Calls `$ACTIONS_ID_TOKEN_REQUEST_URL` with `$ACTIONS_ID_TOKEN_REQUEST_TOKEN`
   to fetch a GitHub OIDC JWT for this run
2. Calls `aws sts assume-role-with-web-identity` with that JWT
3. Sets `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`
   as **masked environment variables** on the runner — all subsequent `aws` CLI
   commands in the job automatically pick them up
4. Credentials expire when the job ends (typically 1 hour max)

---

## Security Properties

| Property | Detail |
|---|---|
| **No static secrets** | `AWS_ROLE_ARN` is just a role ARN — not a credential. Leaking it alone gives an attacker nothing without a valid GitHub OIDC token from your repo. |
| **Short-lived credentials** | Temporary creds expire after ~1 hour. A leaked session token becomes useless quickly. |
| **Repo-scoped** | Trust policy `sub` condition locks the role to your specific repo (and optionally branch/environment). |
| **Full audit trail** | Every `AssumeRoleWithWebIdentity` call is logged in AWS CloudTrail with the GitHub run ID. |
| **No rotation needed** | Nothing to rotate — there are no long-lived keys. |

---

## Common Errors and Fixes

| Error | Cause | Fix |
|---|---|---|
| `Could not load credentials from any providers` | `id-token: write` permission missing | Add `permissions: id-token: write` to the job or workflow |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | OIDC provider not created in AWS, or wrong audience | Create the OIDC provider with audience `sts.amazonaws.com` |
| `Access denied — sub condition mismatch` | Trust policy `sub` value doesn't match the workflow's `sub` claim | Update trust policy `sub` to `repo:<owner>/<repo>:*` to test, then tighten |
| `iam:PassRole denied` | Role missing `iam:PassRole` permission for the instance profile | Add the `iam:PassRole` statement scoped to the instance profile role ARN |
| `InvalidClientTokenId` | Wrong region or STS endpoint issue | Ensure `aws-region` matches the region you're operating in |

---

## References

- [GitHub Docs — OIDC with AWS](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
- [AWS Docs — IAM OIDC Identity Providers](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html)
- [aws-actions/configure-aws-credentials](https://github.com/aws-actions/configure-aws-credentials)
- [GitHub OIDC token claims reference](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/about-security-hardening-with-openid-connect#understanding-the-oidc-token)
