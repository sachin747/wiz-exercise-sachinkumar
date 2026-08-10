# Wiz Technical Exercise — Secure Todo on AWS

A containerised Spring Boot todo application on Amazon EKS, backed by MongoDB
on an EC2 virtual machine, deployed entirely by Terraform and GitHub Actions —
with a set of **deliberate misconfigurations** that AWS-native security services
are configured to detect.

| | |
|---|---|
| Cloud provider | AWS, region set via the `AWS_REGION` GitHub variable (defaults to `us-east-1` locally) |
| Cluster | `sachin-app-cluster` (EKS, private subnets) |
| IaC | Terraform (no CloudFormation) |
| CI/CD | GitHub Actions × 2 pipelines |
| Candidate | Sachin Kumar (`wizexercise.txt`) |

**Every command — local run, deploy, demo, teardown — is in
[COMMANDS.md](COMMANDS.md).**

---

## Architecture

```
                    Internet
                        │
                        ▼
          ┌───────────────────────────────┐
          │ Application Load Balancer     │  public subnets 10.20.0.0/24, 10.20.1.0/24
          │ (provisioned by the AWS Load  │
          │  Balancer Controller from a   │
          │  real Kubernetes Ingress)     │
          └──────────────┬────────────────┘
                         │
   ┌─────────────────────▼───────────────────────┐    ┌──────────────────────┐
   │ EKS worker nodes — PRIVATE subnet, 1 AZ      │    │ MongoDB on EC2       │
   │ 10.20.10.0/24                                │───▶│ public subnet        │
   │ Pod: secure-todo (Spring Boot, non-root)     │27017                      │
   │ MONGODB_URI injected from a k8s Secret       │    │ SSH 22 open to world │
   │                                               │    └──────────┬───────────┘
   │ Single NAT gateway for egress (ECR/EKS/EC2   │               │ daily cron
   │ API calls); no inbound path either way        │               ▼
   └───────────────────────────────────────────────┘   ┌──────────────────────┐
                                                        │ S3 backup bucket     │
                                                        │ PUBLIC read + list   │
                                                        └──────────────────────┘
```

---

## Repository layout

```
infra/bootstrap/       run once, locally — TF state bucket + GitHub OIDC role
infra/terraform/       the environment
  network.tf           VPC, public/private subnets, single NAT gateway (1 AZ)
  vpc-endpoints.tf     free S3 gateway endpoint only
  eks.tf               cluster (2-AZ control plane), private node group (1 AZ), add-ons (vpc-cni NetworkPolicy enforcement on)
  alb-controller.tf    IRSA (OIDC provider + IAM role) for the AWS Load Balancer Controller
  ecr.tf               image registry (immutable tags, scan on push)
  mongodb.tf           MongoDB VM  ← misconfigurations 1–4
  backups.tf           S3 backup bucket ← misconfiguration 5
  security.tf          CloudTrail, EBS encryption by default, Security Hub
k8s/                   flat manifests, applied directly with `kubectl apply -f`
  rbac.yaml            ← misconfiguration 6
  service.yaml          type: ClusterIP — traffic arrives via the Ingress below
  ingress.yaml           the actual Kubernetes Ingress object, class alb
  alb-controller.yaml    AWS Load Balancer Controller — generated, not hand-written; see its header
  alb-controller-serviceaccount.yaml   IRSA role ARN patched in by app.yml at deploy time
  network-policy.yaml   pod egress restricted to MongoDB + DNS only
  examples/             schema references only, never applied
.github/workflows/
  infra.yml            PIPELINE 1 — Terraform
  app.yml              PIPELINE 2 — build, scan, deploy
src/                   Spring Boot application (Java 21)
Dockerfile             multi-stage build, non-root, contains wizexercise.txt
```

---

## Deliberate misconfigurations and how they are detected

Every item below is required by the exercise brief. Each is marked in the source
with a `DELIBERATE MISCONFIGURATION` comment naming the detecting service.

| # | Misconfiguration | Where | Detected by |
|---|---|---|---|
| 1 | **Outdated OS** — Amazon Linux 2 (EOL June 2026, >1 yr behind AL2023) | `infra/terraform/mongodb.tf` | Amazon Inspector EC2 scanning → Security Hub |
| 2 | **SSH open to `0.0.0.0/0`** | `infra/terraform/mongodb.tf` | Security Hub **EC2.13** |
| 3 | **Over-privileged VM role** — `ec2:*` on `*`, so the database server can create and destroy instances | `infra/terraform/mongodb.tf` | Security Hub **IAM.21** |
| 4 | **Outdated MongoDB 6.0.14** (released Jan 2024; the 6.0 series is end-of-life) | `infra/terraform/mongodb.tf` | Amazon Inspector software vulnerability findings → Security Hub |
| 5 | **S3 backup bucket public read + public list** — anyone can `curl` a full `mongodump` | `infra/terraform/backups.tf` | Security Hub **S3.2 / S3.8** |
| 6 | **Pod bound to `cluster-admin`** with a mounted service-account token | `k8s/rbac.yaml` | Trivy Kubernetes scan in the app pipeline |
| — | MongoDB VM in a public subnet with a public IP | `infra/terraform/mongodb.tf` | Security Hub **EC2.9** |

### Requirements deliberately *not* weakened

The brief also mandates two controls that stay tight, and they are implemented:

- **MongoDB reachable only from Kubernetes.** Port 27017 is open solely to the
  EKS cluster security group — never to `0.0.0.0/0`
  (`aws_vpc_security_group_ingress_rule.mongo_from_eks`).
- **Database authentication required.** `security.authorization: enabled` in
  `mongod.conf`; the app user's password is a single GitHub Actions secret
  (`MONGO_APP_PASSWORD`, no AWS Secrets Manager involved), consumed by both
  Terraform (to create the Mongo user) and `app.yml` (to build `MONGODB_URI`
  for the Kubernetes Secret at deploy time). It never appears in git.

---

## Cloud native security

### Audit

- **CloudTrail** — multi-region trail, global service events, log file
  validation, dedicated encrypted bucket with a TLS-only policy.
- **EKS control plane audit logging** — all five streams (`api`, `audit`,
  `authenticator`, `controllerManager`, `scheduler`) to CloudWatch Logs with
  90-day retention. This satisfies the exercise's control-plane audit logging
  requirement directly.

### Preventative controls

These **block** a bad state rather than reporting it after the fact:

| Control | Where | What it stops |
|---|---|---|
| EBS encryption by default (account-wide) | `security.tf` | Any unencrypted volume being created in the region, regardless of who asks |
| Pod Security Admission `restricted` on the app namespace | `k8s/namespace.yaml` | The API server refuses privileged pods, host namespaces, hostPath mounts. Demo: `kubectl -n secure-todo run bad --image=busybox --privileged` is rejected |
| ECR immutable tags + scan on push | `ecr.tf` | A pushed tag can never be overwritten — the digest CI scanned is the digest that runs |
| IMDSv2 required, hop limit 1 | `eks.tf`, `mongodb.tf` | SSRF from a container reaching node instance credentials |
| S3 TLS-only bucket policy | `security.tf` | Plaintext access to the audit log bucket |
| NetworkPolicy — app pod egress restricted to MongoDB + DNS | `k8s/network-policy.yaml`, `eks.tf` (`enableNetworkPolicy`) | A compromised pod (misconfiguration 6) reaching anywhere else inside the VPC — other pods, the EKS API, other services. Enforced by the VPC CNI's built-in eBPF agent |
| GitHub OIDC federation | both pipelines | Long-lived AWS access keys existing in GitHub at all |

### NAT gateway, single AZ

Earlier revisions of this repo went NAT-free (VPC interface endpoints only)
on the theory that it was both cheaper and more secure. Checked against
current AWS pricing, that wasn't actually true for this shape: six interface
endpoints across 2 AZs run ~$0.12/hr, more than a single NAT gateway's
~$0.045/hr — so the endpoints-only design cost more while adding five extra
resources (a security group plus six endpoints) for the same private-subnet
egress need. `vpc-endpoints.tf` now keeps only the free S3 gateway endpoint
(no hourly charge, no data charge — keeps ECR's S3-backed image layer pulls
off the NAT gateway entirely); everything else routes through one NAT
gateway in `network.tf`.

This does mean private subnets now have an outbound path (through the NAT),
where the endpoints-only design had none at all — a real, small reduction in
blast-radius-if-compromised versus the previous design, traded for lower
cost and less to maintain. There is still no *inbound* path either way.

The EKS node group and the NAT gateway both sit in the same single AZ
(`private-0`/`public-0`) rather than spread across both — nodes are billed
per-instance regardless of AZ count, so multi-AZ bought no cost benefit here,
only cross-AZ resilience this lab doesn't need. The cluster's control plane
still registers both private subnets; EKS requires at least 2 AZs for that
regardless.

SSM Session Manager into the worker nodes was considered and dropped: the
exercise requires demonstrating `kubectl`, not node-level shell access.
`kubectl exec` into pods is unaffected either way.

### Detective controls

- **Security Hub** — AWS Foundational Security Best Practices + CIS 1.4.0,
  covering every misconfiguration in the table above (public SSH, public
  bucket, over-privileged IAM, public EC2 IP) plus Inspector's EC2/software
  vulnerability findings. This is the single screen to demo.

GuardDuty and AWS Config were evaluated and dropped: the exercise requires
only one detective control, and running three overlapping tools added cost
and setup without covering anything Security Hub's standards don't already
catch. Security Hub was kept over the other two because its checks evaluate
continuously against existing resource config — findings are visible
immediately rather than needing triggered activity (GuardDuty) or a recorder
pipeline to spin up first (Config), which is more reliable for a scheduled
demo.

> If the account already has Security Hub enabled, set `enable_security_hub`
> to `false` — it's an account-and-region singleton and a second one will
> fail the apply.

---

## Pipeline security

**Pipeline 1 — `infra.yml`** (`terraform fmt` → `validate` → Checkov → Trivy IaC
→ gitleaks → `plan` on PR → `apply` on `main`)

**Pipeline 2 — `app.yml`** (tests → build → verify `wizexercise.txt` → Trivy
image scan **reporting** → push → deploy → verify running pod)

Repository-level controls:

- `.github/CODEOWNERS` — review required on every change, tightest on `infra/`
- gitleaks secret scanning on every infra run
- `environment: aws` on every AWS-touching job, so you can require a manual
  approver before `apply`
- **Branch protection on `main` must be configured in the GitHub UI** — see the
  TODO list below

Every Trivy/Checkov scan (IaC, container image, Kubernetes config) runs in
**reporting** mode — findings print in full to the job log rather than
failing the build, since this is a security demo and the exercise requires
those exact findings to exist for review rather than to be blocked. No
SARIF upload to the Security tab either: this account's plan doesn't
include GitHub Advanced Security on a private repo.

`app.yml` is a single job on purpose — the image Trivy scans is byte-for-byte
the image that is pushed and deployed. Splitting build and deploy would rebuild
the image and could ship an unscanned layer. It also reads infrastructure facts
from the AWS APIs rather than downloading the Terraform state file, so the
plaintext state (which contains the MongoDB password) never lands on a runner.

### Kubernetes tooling stays minimal — no Kustomize, no Helm at runtime

`k8s/` is flat manifests — nothing here uses overlays or patches, so
`kubectl apply -f k8s/<file>` does the same job Kustomize would have, with one
less tool. The app image tag is set afterwards with
`kubectl set image deployment/secure-todo application=<image> -n secure-todo`.

The app is exposed by a real Kubernetes `Ingress` (`k8s/ingress.yaml`),
served by the AWS Load Balancer Controller (`k8s/alb-controller.yaml`),
satisfying both halves of "exposed via ... a Kubernetes ingress and CSP load
balancer" literally, not just the load-balancer half. This used to be a bare
`Service type: LoadBalancer` — no controller, no IAM role, one less moving
part — and that trade-off is still a reasonable one for a single-route app;
switched over once a real `Ingress` object became worth demonstrating.

`k8s/alb-controller.yaml` is a **generated file**, not hand-written. The
controller's chart bakes a self-signed webhook TLS certificate in at render
time (Helm's `genSelfSignedCert`), which isn't something safe to fabricate by
hand — so it's rendered for real, once, via `render-alb-controller.ps1`,
which runs the official Helm chart inside a throwaway Docker container. Helm
never touches the cluster and isn't a pipeline dependency; the output is
plain YAML applied with `kubectl apply`, same as everything else here. The
IAM policy the controller runs under
(`infra/terraform/files/alb-controller-iam-policy.json`) is likewise copied
verbatim from the upstream repo rather than hand-transcribed — it's about
250 lines covering ALB, target group and security group management, easy to
get subtly wrong by guessing.

The ServiceAccount's IAM role ARN doesn't exist until Terraform creates it,
so it's kept out of the rendered file entirely — `app.yml` looks the role up
by name (`aws iam get-role --role-name sachin-app-alb-controller`), applies
`k8s/alb-controller-serviceaccount.yaml`, and patches the real ARN in via
`kubectl annotate --overwrite` before the controller's pods start.

---

## Deployment runbook

### 0. One-time bootstrap (local, admin credentials)

```bash
cd infra/bootstrap
terraform init
terraform apply -var="github_repository=<owner>/<repo>" -var="aws_region=<your aws region>"
terraform output           # note both values
```

`-var="aws_region=..."` only needs to be passed if you're not using the default (`us-east-1`) — see `infra/bootstrap/variables.tf`. Whatever region you land on here is the same one you'll set as `AWS_REGION` below; it's the only place the region needs to be chosen, everything else reads it from that one GitHub variable.

Then set these in **GitHub → Settings → Secrets and variables → Actions**:

| Type | Name | Value |
|---|---|---|
| Variable | `AWS_REGION` | the region you deployed the state bucket into above, e.g. `us-east-1` |
| Variable | `AWS_DEPLOY_ROLE_ARN` | `github_deploy_role_arn` output |
| Variable | `TF_STATE_BUCKET` | `state_bucket_name` output |
| Variable | `MONGO_SSH_PUBLIC_KEY` | contents of your `~/.ssh/id_ed25519.pub` |
| Variable | `CLUSTER_ADMIN_ROLE_ARN` | IAM role you assume locally for `kubectl` (may be empty) |
| Secret | `TODO_USER_PASSWORD` | long random string |
| Secret | `TODO_ADMIN_PASSWORD` | different long random string |
| Secret | `MONGO_APP_PASSWORD` | long random string — the only MongoDB credential; no AWS Secrets Manager |

Also create a GitHub **Environment** named `aws`.

### 1. Infrastructure

Actions → *Infrastructure (Terraform)* → Run workflow → `apply`.
Takes ~20 minutes; the EKS control plane dominates.

### 2. Application

Actions → *Application (build, scan, deploy)* → Run workflow.
The job summary prints the load balancer hostname and the contents of
`wizexercise.txt` read out of the live pod.

### 3. Tear down

Run `kubectl delete -f k8s/ingress.yaml` first, and wait for it to finish —
that's what tells the AWS Load Balancer Controller to actually delete the
ALB it provisioned. Terraform doesn't know that ALB exists (the controller
created it directly via the AWS API, not Terraform), so skipping this step
leaves it orphaned and the VPC destroy will hang on its ENIs in the public
subnets. Once the Ingress is gone, `kubectl delete -f k8s/` for the rest,
then Actions → *Infrastructure (Terraform)* → Run workflow → `destroy`.

---

## Demo script

```bash
# Kubernetes CLI
aws eks update-kubeconfig --name sachin-app-cluster --region <your AWS_REGION>
kubectl get nodes -o wide                        # all node IPs are 10.20.1x.x = private
kubectl get pods,svc -n secure-todo

# wizexercise.txt in the RUNNING container
kubectl exec -n secure-todo deploy/secure-todo -- cat /app/wizexercise.txt

# MONGODB_URI really is an env var sourced from a Secret
kubectl exec -n secure-todo deploy/secure-todo -- printenv MONGODB_URI

# The web app, then prove the data landed in MongoDB
kubectl get ingress secure-todo -n secure-todo \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# ... add a todo in the browser, then:
ssh ec2-user@<mongo_public_ip>
mongosh "mongodb://todo_app:<pw>@127.0.0.1:27017/todo?authSource=todo" \
  --eval 'db.todos.find().pretty()'

# Misconfiguration proof
curl "https://<backup_bucket>.s3.<your AWS_REGION>.amazonaws.com/"    # anonymous listing
kubectl auth can-i '*' '*' --as=system:serviceaccount:secure-todo:secure-todo

# Preventative control proof
kubectl -n secure-todo run bad --image=busybox --privileged    # rejected by PSA

# Detective control proof
# AWS console → Security Hub → Findings, filtered to the sachin-app resources
```

---

## Open TODOs

| # | Item | Why it is deferred | Impact and fix |
|---|---|---|---|
| 1 | **Custom domain + ACM certificate** | No domain registered yet | The ALB serves **HTTP on port 80 only**. Once a certificate exists, add to `k8s/ingress.yaml`: a second listener via `alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'` and `alb.ingress.kubernetes.io/certificate-arn: <acm-arn>`. Then set `SESSION_COOKIE_SECURE=true` on the deployment. |
| 2 | **~~No Kubernetes `Ingress` object~~ — done** | — | Was `Service type: LoadBalancer` only. Now a real `Ingress` (`k8s/ingress.yaml`) served by the AWS Load Balancer Controller — see "Kubernetes tooling stays minimal" above for how the controller manifest was produced without adding Helm as a pipeline dependency. |
| 3 | **EKS API endpoint is public (`0.0.0.0/0`)** | GitHub-hosted runners have dynamic egress IPs | Authentication is still SigV4 + EKS Access Entries, so there is no anonymous access — but the endpoint is internet-reachable. Fix by moving CI to a self-hosted runner inside the VPC, then restricting `public_access_cidrs`. Flagged in `eks.tf` as an accepted lab tradeoff, **not** one of the exercise's required weaknesses. |
| 4 | **CI role holds `AdministratorAccess`** | The pipeline creates VPCs, EKS, IAM and Security Hub | Scope down to least privilege once the resource set stops changing. See `infra/bootstrap/main.tf`. |
| 5 | **Branch protection rules** | Cannot be expressed inside the repository | Configure in the GitHub UI: require a PR, require the `Scan IaC` and `Build, scan and deploy` checks, require Code Owner review, require signed commits. |
| 6 | **Confirm the EKS version** | `kubernetes_version` defaults to `1.33` | Verify it is still supported before the first apply: `aws eks describe-cluster-versions --region <your AWS_REGION>` |
| 7 | **Amazon Inspector** | Not enabled by Terraform | Misconfigurations 1 and 4 (outdated OS and MongoDB) are only surfaced once Inspector EC2 scanning is switched on. Enable it in the console, or add `aws_inspector2_enabler`, before the demo. |
| 8 | **NetworkPolicy doesn't cover the Kubernetes API server path** | `k8s/network-policy.yaml`'s egress rules are MongoDB + DNS only | The misconfiguration 6 demo (`wget https://kubernetes.default.svc/...` from inside the app pod) needs that policy temporarily removed first — see COMMANDS.md §7. Whether an `ipBlock` rule could cover it too depends on exactly where the VPC CNI's eBPF agent evaluates egress relative to kube-proxy's DNAT; not asserted here without testing against the live cluster. |
| 9 | **ALB controller's IAM policy needs re-syncing on upgrade** | `infra/terraform/files/alb-controller-iam-policy.json` is copied from a specific upstream release (v2.13.0) | If `render-alb-controller.ps1`'s chart `--version` is ever bumped, re-copy `docs/install/iam_policy.json` from the matching tag in `kubernetes-sigs/aws-load-balancer-controller` too — the policy and controller version can drift out of sync otherwise. |

---

## Local test run

A full dry-run of the AWS environment on Docker Desktop — same Dockerfile, same
MongoDB major version, same `MONGODB_URI` injection mechanism:

```bash
docker compose up --build            # app + MongoDB 6.0
```

Then open <http://localhost:8080> and log in as `todo-user` / `todo-user-local`.

Two helper scripts automate the whole check on Windows — double-click either and
read the `.log` file it drops beside itself (both logs are gitignored):

| Script | What it proves |
|---|---|
| `run-local-test.bat` | Clean rebuild, both containers healthy, `/actuator/health` returns UP, `wizexercise.txt` is in the running container, `MONGODB_URI` is set, MongoDB accepts the authenticated connection |
| `run-verify-data.bat` | Logs in through the real form (handling CSRF), creates a todo, then reads that exact document back out of MongoDB — the PDF's "prove the data is in the database" requirement |

Verification, matching the AWS demo script step for step:

```bash
# wizexercise.txt is in the running container
docker compose exec app cat /app/wizexercise.txt

# MONGODB_URI really is an environment variable
docker compose exec app printenv MONGODB_URI

# after adding a todo in the browser, prove it reached the database
docker compose exec mongodb mongosh \
  "mongodb://todo_app:todo_dev_password@127.0.0.1:27017/todo?authSource=todo" \
  --quiet --eval "db.todos.find().pretty()"

docker compose down -v               # -v also drops the MongoDB volume
```

> If you previously started the older `mongo:8.0` compose file, run
> `docker compose down -v` first. MongoDB refuses to start on a data directory
> written by a newer version.

To run the app on the host instead of in a container, start only the database
(`docker compose up -d mongodb`), copy `.env.example` to `.env`, then
`mvn spring-boot:run`. This path needs JDK 21 locally; the container path does
not.

The local logins are development fallbacks defined in `application.yml`. In the
cluster every value comes from the `secure-todo-secrets` Kubernetes Secret.

---

## Application notes

Three layers, Java 21 / Spring Boot 3.5:

- **Presentation** — Thymeleaf templates, no JavaScript dependency
- **Application** — `TodoService`, with per-user ownership enforced on every
  repository lookup so one user cannot read another's todos by ID
- **Data** — Spring Data MongoDB via the official MongoDB Java driver
  (MongoDB is not a JDBC database, so there is no JDBC connector)

Application-layer hardening: Spring Security form login, BCrypt hashes, CSRF
protection, a restrictive Content-Security-Policy, `frameOptions: deny`,
HttpOnly/SameSite cookies, and actuator exposure limited to health probes.

`wizexercise.txt` enters the image via a single Dockerfile instruction:

```dockerfile
COPY --chown=10001:10001 wizexercise.txt /app/wizexercise.txt
```

It is validated twice in the pipeline — once against the built image before the
push, and once with `kubectl exec` against the running pod after rollout.
