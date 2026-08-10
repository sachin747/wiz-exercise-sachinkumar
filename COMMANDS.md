# Command reference

Every command needed to run, verify, deploy and demo this exercise.
Copy-paste order top to bottom.

```
Project      sachin-app
Cluster      sachin-app-cluster
Region       set by the AWS_REGION GitHub variable (us-east-1 default for local runs)
Namespace    secure-todo
```

---

## Requirements checklist — EKS section of the PDF

Every bullet, where it's implemented, and the exact command that proves it
right now (local proof today, EKS proof in §6 once deployed).

| # | Requirement | Implemented in | Proof command |
|---|---|---|---|
| 1 | Containerized app you (re-)built, leverages MongoDB | `Dockerfile` (multi-stage build); `MONGODB_URI` in `application.yml` | §1 `docker compose up --build` |
| 2 | Kubernetes cluster deployed in a private subnet | `infra/terraform/eks.tf` — `aws_eks_node_group.app` sits only in `aws_subnet.private[*]` | §6 `kubectl get nodes -o wide` → every IP is `10.20.1x.x` |
| 3 | MongoDB access configured via a Kubernetes environment variable | `k8s/deployment.yaml` — `MONGODB_URI` from `secretKeyRef` | §1 `docker compose exec app printenv MONGODB_URI` / §6 same via `kubectl exec` |
| 4 | `wizexercise.txt` with your name in the image; show how it got in and prove it's in the running container | `Dockerfile`: `COPY --chown=10001:10001 wizexercise.txt /app/wizexercise.txt`; verified automatically by `.github/workflows/app.yml` before push and after deploy | §1 `docker compose exec app cat /app/wizexercise.txt` / §6 `kubectl exec ... cat /app/wizexercise.txt` |
| 5 | Container app assigned cluster-wide Kubernetes admin role | `k8s/rbac.yaml` — `ClusterRoleBinding` to `cluster-admin` | §7 `kubectl auth can-i '*' '*' --as=system:serviceaccount:secure-todo:secure-todo` |
| 6 | Exposed via a Kubernetes ingress and CSP load balancer | `k8s/ingress.yaml` (`kind: Ingress`, class `alb`) served by the AWS Load Balancer Controller (`k8s/alb-controller.yaml`), which provisions a real ALB | §6 `kubectl get ingress secure-todo -n secure-todo` |
| 7 | Demonstrate `kubectl` during the demo | n/a — live | §6, any command |
| 8 | Demonstrate the web app and prove the data is in the database | ALB hostname in the browser, then read the same document back with `mongosh` | §6 "Prove the data is in the database" |
| 9 | *(Optional)* Simulate an attack to show preventative/detective controls working | No internet egress from the app pod (network + NetworkPolicy layers); CloudTrail catching a simulated static-key creation | §7b |

---

## 0. Prerequisites — verify your tools

Run once before anything else. `aws` is already configured per your setup;
this just confirms the region and identity match what the Terraform expects.

```powershell
aws --version
aws sts get-caller-identity                 # confirms your credentials work
aws configure get region                    # note it — pass -region <your region> explicitly if different

docker --version
git --version
kubectl version --client                    # needed for §5/§6/§7 manual commands
```

If `kubectl` is missing:

```powershell
winget install -e --id Kubernetes.kubectl
```

No Kustomize, and no Helm as a *runtime* dependency — `k8s/` is flat
manifests applied with plain `kubectl apply -f`. The one exception is
`k8s/alb-controller.yaml`, which was rendered once from the real AWS Load
Balancer Controller Helm chart (via Docker, see `render-alb-controller.ps1`
in the repo root) and then committed as plain YAML — nothing in the deploy
pipeline runs Helm. See the README, "Kubernetes tooling stays minimal", for
why that manifest specifically couldn't be hand-written.

---

## 1. Local — Docker Compose

Runs the real Dockerfile against MongoDB 6.0, the same major version deployed
on the AWS VM. Nothing here touches AWS.

```powershell
cd C:\wiz-repos\wiz-exercise-sachinkumar

# Old volumes from a newer MongoDB will block startup — always clear first
docker compose down -v

# Build the image and start app + database
docker compose up --build -d

# Watch the app boot; wait for "Started SecureTodoApplication"
docker compose logs -f app

# Both containers should be Up, mongodb marked (healthy)
docker compose ps
```

Open <http://localhost:8080> — log in as `todo-user` / `todo-user-local`.

### Verify

```powershell
# Health probes used by the Kubernetes readiness/liveness checks
curl http://localhost:8080/actuator/health

# REQUIREMENT: wizexercise.txt exists in the running container
docker compose exec app cat /app/wizexercise.txt

# REQUIREMENT: MongoDB access is configured by environment variable
docker compose exec app printenv MONGODB_URI

# REQUIREMENT: prove the data is in the database
# (add a todo in the browser first, then run this)
docker compose exec mongodb mongosh `
  "mongodb://todo_app:todo_dev_password@127.0.0.1:27017/todo?authSource=todo" `
  --quiet --eval "db.todos.find().pretty()"
```

### Or run the two scripts

```powershell
.\run-local-test.bat      # full rebuild + all checks  -> local-test-output.log
.\run-verify-data.bat     # login, create todo, read it back from MongoDB
                          #                            -> verify-data-output.log
```

### Stop

```powershell
docker compose down -v    # -v also deletes the MongoDB volume
```

---

## 1b. Which JDK is actually running the app?

**Not the one on your desktop.** Both the compile and the run happen inside
containers, defined by the two `FROM` lines in the `Dockerfile`:

| Stage | Image | Purpose |
|---|---|---|
| `build` | `maven:3.9.9-eclipse-temurin-21-alpine` | JDK 21 + Maven 3.9.9 — compiles and packages the jar |
| runtime | `eclipse-temurin:21-jre-alpine` | **JRE 21** only — no compiler ships in the final image |

Confirmed from the running container's own startup log:

```
Starting SecureTodoApplication v0.0.1-SNAPSHOT using Java 21.0.11 with PID 1
platform: Java/Eclipse Adoptium/21.0.11+10-LTS
Servlet engine: Apache Tomcat/10.1.44      (embedded, Spring Boot 3.5.5)
```

So the app runs on **Eclipse Temurin (Adoptium) JRE 21.0.11+10-LTS**, as
non-root uid 10001, on Alpine, under WSL2. Your host JDK is irrelevant for the
`docker compose` path — it only matters for the "run on host" path in §1d.

```powershell
# Ask the container directly
docker compose exec app java -version
docker compose exec app sh -c "id -un; ls -l /app"

# Compare with your host (only needed for the §1d path)
java -version
mvn -v
echo $env:JAVA_HOME
```

`pom.xml` sets `<java.version>21</java.version>`, so the host path needs
**JDK 21 or newer**. Java 17 or below will fail to compile.

---

## 1c. Restart after changing application code — container path

This is the path to use: it rebuilds the same artifact the pipeline builds, so
what you test locally is what deploys to EKS.

```powershell
cd C:\wiz-repos\wiz-exercise-sachinkumar

# 1. Edit your Java / Thymeleaf / CSS files as normal.

# 2. Rebuild the image and recreate ONLY the app container.
#    --build is essential; without it Compose silently reuses the old image.
#    Do NOT use `down -v` here — that would wipe your MongoDB test data.
docker compose up --build -d app

# 3. Watch it come back up; wait for "Started SecureTodoApplication"
docker compose logs -f app        # Ctrl+C to stop tailing

# 4. Confirm the new container is running (note the fresh CREATED time)
docker compose ps
```

Typical rebuild is 30–60 seconds. The Dockerfile copies `pom.xml` and runs
`dependency:go-offline` *before* `COPY src ./src`, so a source-only change
reuses the cached Maven dependency layer and never re-downloads from Maven
Central.

**Variations**

```powershell
# Changed pom.xml (added a dependency)? Same command — the pom layer is
# invalidated and dependencies are refetched automatically.
docker compose up --build -d app

# Force a completely clean rebuild, ignoring all layer cache
docker compose build --no-cache app
docker compose up -d --force-recreate app

# Restart without rebuilding (e.g. only changed an environment variable
# in compose.yaml)
docker compose up -d app

# Just bounce the process, no image change at all
docker compose restart app
```

**Gotchas**

- Changing `compose.yaml` env vars needs `docker compose up -d app`, not
  `restart` — `restart` reuses the old container definition.
- `spring-boot-devtools` is not a dependency, so there is no hot reload. Every
  code change requires a rebuild.
- If port 8080 is reported as in use, something else is bound to it:
  `netstat -ano | findstr :8080`.

---

## 1d. Restart after changing code — host path (faster iteration)

Skips Docker for the app and runs it straight from Maven. Needs **JDK 21+** and
Maven on your desktop. Useful for tight edit/run loops; always re-verify with
§1c before deploying, since this does not exercise the Dockerfile.

```powershell
cd C:\wiz-repos\wiz-exercise-sachinkumar

# 1. Free port 8080 — stop the containerised app but KEEP the database running
docker compose stop app
docker compose up -d mongodb

# 2. Point the app at MongoDB. On the host it is localhost:27017 (the published
#    port), NOT the compose service name "mongodb".
$env:MONGODB_URI      = "mongodb://todo_app:todo_dev_password@localhost:27017/todo?authSource=todo"
$env:APP_USER_NAME    = "todo-user"
$env:APP_USER_PASSWORD  = "todo-user-local"
$env:APP_ADMIN_NAME   = "todo-admin"
$env:APP_ADMIN_PASSWORD = "todo-admin-local"
$env:SESSION_COOKIE_SECURE = "false"

# 3. Run. Ctrl+C to stop, then re-run after each code change.
mvn spring-boot:run

# Just the tests
mvn -B test

# Build the jar and run it directly
mvn -B clean package
java -jar target\secure-todo-0.0.1-SNAPSHOT.jar
```

To go back to the fully containerised setup:

```powershell
# Ctrl+C the Maven process first
docker compose up --build -d app
```

---

## 1e. Validate the Kubernetes manifests — no cluster, no AWS needed

Catches YAML mistakes for free before you spend 20 minutes waiting on an EKS
cluster to find out the hard way. `k8s/` is plain manifests now — no
Kustomize step to render first.

```powershell
cd C:\wiz-repos\wiz-exercise-sachinkumar

# Structural validation against the Kubernetes API schema — no cluster needed
kubectl apply -f k8s\ --dry-run=client

# Explicitly confirm the things NOT meant to be applied by the command above
# stay out of it (they live in subfolders, which -f without -R never enters)
kubectl apply -f k8s\ --dry-run=client -o name

# The same scanner .github/workflows/app.yml runs, locally.
# The cluster-admin binding is a REQUIRED finding, so don't expect this clean —
# read it to make sure nothing UNEXPECTED shows up.
trivy config k8s\ --severity HIGH,CRITICAL
```

---

## 1f. Push to GitHub

**Do §3 (bootstrap) and set the GitHub secrets/variables table BEFORE this
push.** Both pipelines are wired to trigger automatically on a push to `main`
— if the AWS role/bucket variables don't exist yet, they'll simply fail on
their first "configure AWS credentials" step. Not destructive, just re-run
them from the Actions tab once the variables are set.

```powershell
cd C:\wiz-repos\wiz-exercise-sachinkumar

git init
git add .
git status                     # confirm nothing under .gitignore snuck in —
                                # no *.tfstate, .env, or k8s\secret.yaml
git commit -m "Wiz technical exercise: Spring Boot + MongoDB on EKS"
git branch -M main

# Create the GitHub repo first (web UI), then:
git remote add origin https://github.com/<owner>/<repo>.git
git push -u origin main

# Or, with the GitHub CLI, do both in one step:
gh repo create <owner>/<repo> --private --source=. --remote=origin --push
```

### What fires automatically after this push

Both workflows trigger on the same push because the commit touches both
`infra/**` and application/`k8s/**` files:

- **`infra.yml`** starts applying immediately — the ~20 minute EKS build.
- **`app.yml`** also starts immediately, but its "Discover infrastructure"
  step calls `aws ecr describe-repositories` / `aws ec2 describe-instances`,
  which don't exist yet. **It will fail — this is expected on the first
  push.** Once `infra.yml` finishes, re-run it:

```powershell
gh run list --workflow=app.yml --limit 1
gh run rerun <run-id>

# or without the GitHub CLI: Actions tab -> Application (build, scan, deploy)
# -> the failed run -> "Re-run all jobs"
```

---

## 1g. Run on local Kubernetes (Docker Desktop) — no AWS involved

Proves the same manifests in `k8s/` actually work on a real Kubernetes API
server before ever touching EKS. Uses Docker Desktop's built-in cluster, not
minikube/kind, and reuses the MongoDB container from §1's `docker compose`
run rather than spinning up a second one (it's already got the `todo_app`
user from `docker/mongo-init.js`, and a second container can't bind the same
host port 27017 anyway).

```powershell
cd C:\wiz-repos\wiz-exercise-sachinkumar

# 0. Safety: point kubectl at Docker Desktop, NOT a real EKS cluster. If you
#    have ever run `aws eks update-kubeconfig`, your current-context could
#    be that cluster right now -- check before applying anything.
kubectl config get-contexts
kubectl config use-context docker-desktop

# 1. Build the image locally. No registry involved -- Docker Desktop's
#    Kubernetes shares the same image store as `docker build`.
docker build -t secure-todo:local .

# 2. MongoDB: reuse the container from §1 (`docker compose up`). If it isn't
#    already running, start it: docker compose up -d mongodb
docker ps --filter "name=wiz-exercise-sachinkumar-mongodb-1"

# 3. Namespace, RBAC (misconfiguration 6), NetworkPolicy (applies cleanly
#    but isn't enforced here -- Docker Desktop's Kubernetes has no CNI that
#    implements it; that's only true on EKS with vpc-cni configured, eks.tf)
kubectl apply -f k8s\namespace.yaml
kubectl apply -f k8s\rbac.yaml
kubectl apply -f k8s\network-policy.yaml

# 4. Secret -- same todo_app credentials docker/mongo-init.js already
#    created in that Mongo container. host.docker.internal is Docker
#    Desktop's standing DNS name for "the host machine", reachable from
#    both plain containers and pods in its local Kubernetes.
kubectl create secret generic secure-todo-secrets `
  --namespace secure-todo `
  --from-literal=mongodb-uri="mongodb://todo_app:todo_dev_password@host.docker.internal:27017/todo?authSource=todo" `
  --from-literal=user-name=todo-user `
  --from-literal=user-password=localdemo-user-pw `
  --from-literal=admin-name=todo-admin `
  --from-literal=admin-password=localdemo-admin-pw `
  --dry-run=client -o yaml | kubectl apply -f -

# 5. Deploy + service, then point the deployment at the local image --
#    same two-step pattern app.yml uses against EKS. The Service is
#    `type: ClusterIP` now (real traffic arrives via the Ingress + ALB
#    controller on the actual cluster), which Docker Desktop can't expose to
#    localhost on its own -- don't bother applying k8s/ingress.yaml or
#    k8s/alb-controller.yaml here, there's no AWS API for the controller to
#    talk to locally. Use kubectl port-forward instead (step 6).
kubectl apply -f k8s\deployment.yaml
kubectl apply -f k8s\service.yaml
kubectl set image deployment/secure-todo application=secure-todo:local -n secure-todo
kubectl rollout status deployment/secure-todo -n secure-todo --timeout=120s

# 6. Verify -- identical pod/env checks as the real cluster; reach the app
#    itself through a port-forward since there's no LoadBalancer here.
kubectl get pods,svc -n secure-todo -o wide
kubectl exec -n secure-todo deploy/secure-todo -- cat /app/wizexercise.txt
kubectl exec -n secure-todo deploy/secure-todo -- printenv MONGODB_URI
Start-Job { kubectl port-forward -n secure-todo svc/secure-todo 8081:80 }
Start-Sleep -Seconds 2
Start-Process "http://localhost:8081/"
# When done: Get-Job | Stop-Job; Get-Job | Remove-Job
```

### Teardown

```powershell
kubectl delete namespace secure-todo
kubectl delete clusterrolebinding secure-todo-cluster-admin
# Leave the Mongo container running if §1's docker compose testing still needs it.
```

### Troubleshooting this specific path

| Symptom | Cause and fix |
|---|---|
| `docker run -d --name local-mongo -p 27017:27017 ...` fails silently | Port 27017 is already bound by the `docker compose` Mongo container from §1. Don't start a second one -- reuse it (step 2 above). |
| Pod `CrashLoopBackOff`, logs show a Mongo auth failure | The Secret's credentials don't match the actual running Mongo container. If you reused compose's container, the only valid user is `todo_app` / `todo_dev_password` on db `todo` (`docker/mongo-init.js`) -- not an admin/root user you invented. |
| `kubectl config use-context docker-desktop` fails, context doesn't exist | Kubernetes isn't enabled in Docker Desktop yet: Settings → Kubernetes → check "Enable Kubernetes" → Apply & Restart. |
| `kubectl get ...` against `secure-todo` returns nothing, not even an error | Usually just a slow first query right after enabling Kubernetes or restarting Docker Desktop -- retry after a few seconds rather than assuming the cluster is broken. |
| `kubectl exec` output doesn't show up when redirected into a transcript (`Start-Transcript`) | A `Start-Transcript`/PowerShell-5.1-specific quirk, not a real failure -- redirect that one command straight to a file (`... >> out.txt 2>&1`) instead of relying on the transcript. |

---

## 2. Terraform — static checks (no AWS credentials needed)

```powershell
# Formatting gate that the infra pipeline enforces
terraform fmt -check -recursive infra\

# Syntax and reference validation, no backend, no AWS calls
cd infra\terraform
terraform init -backend=false
terraform validate
cd ..\..
```

---

## 3. Bootstrap — run ONCE, locally, with admin credentials

Creates the Terraform state bucket and the GitHub OIDC role. Everything after
this runs from CI.

```powershell
cd infra\bootstrap
terraform init
terraform apply -var="github_repository=<owner>/<repo>"
terraform output          # note state_bucket_name and github_deploy_role_arn
cd ..\..
```

**`CLUSTER_ADMIN_ROLE_ARN` matters more than it looks.** By default, EKS grants
cluster-admin only to whoever's AWS identity *creates* the cluster — that's the
GitHub Actions role, not you. Skip this variable and `kubectl` from your
desktop will authenticate fine and then get `Unauthorized` on every request.
Find your own identity and use it here:

```powershell
aws sts get-caller-identity --query Arn --output text
```

Then in **GitHub → Settings → Secrets and variables → Actions**:

| Type | Name | Value |
|---|---|---|
| Variable | `AWS_DEPLOY_ROLE_ARN` | `github_deploy_role_arn` output |
| Variable | `TF_STATE_BUCKET` | `state_bucket_name` output |
| Variable | `MONGO_SSH_PUBLIC_KEY` | contents of `~/.ssh/id_ed25519.pub` |
| Variable | `CLUSTER_ADMIN_ROLE_ARN` | your ARN from the command above |
| Secret | `TODO_USER_PASSWORD` | long random string |
| Secret | `TODO_ADMIN_PASSWORD` | different long random string |

Also create a GitHub **Environment** named `aws`.

If you forget this and apply anyway, it's not a redo-everything situation —
add the variable and re-run just the infra pipeline; `eks_access_entry.admin`
is additive and Terraform will create it on the next apply.

---

## 4. Infrastructure

### Preferred — pipeline

`Actions → Infrastructure (Terraform) → Run workflow → apply`  (~20 min)

### Manual equivalent

```powershell
cd infra\terraform
terraform init -backend-config="bucket=<state_bucket_name>"
terraform plan  -var="ssh_public_key=<your-public-key>" -var="mongo_app_password=<the-MONGO_APP_PASSWORD-secret-value>"
terraform apply -var="ssh_public_key=<your-public-key>" -var="mongo_app_password=<the-MONGO_APP_PASSWORD-secret-value>"
terraform output
cd ..\..
```

---

## 5. Application → Kubernetes

### Preferred — pipeline

`Actions → Application (build, scan, deploy) → Run workflow`

The job summary prints the load balancer hostname and the contents of
`wizexercise.txt` read out of the live pod.

### Manual equivalent

```powershell
# --- connect kubectl to the cluster -------------------------------------
aws eks update-kubeconfig --name sachin-app-cluster --region <your AWS_REGION>
kubectl get nodes                       # confirms you have API access

# --- discover the infrastructure Terraform built ------------------------
$ECR = aws ecr describe-repositories --repository-names sachin-app `
        --query 'repositories[0].repositoryUri' --output text
$MONGO_IP = aws ec2 describe-instances `
        --filters "Name=tag:Name,Values=sachin-app-mongodb" "Name=instance-state-name,Values=running" `
        --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text
$TAG = "manual-" + (Get-Date -Format "yyyyMMddHHmmss")   # ECR tags are immutable

# --- build, scan, push ---------------------------------------------------
aws ecr get-login-password --region <your AWS_REGION> | `
  docker login --username AWS --password-stdin $ECR.Split('/')[0]

docker build -t "${ECR}:${TAG}" .

# Same reporting-only scan the pipeline runs — informational, doesn't block
trivy image --severity HIGH,CRITICAL --exit-code 0 "${ECR}:${TAG}"

docker push "${ECR}:${TAG}"

# --- create the application secret --------------------------------------
# No AWS Secrets Manager: MONGO_APP_PASSWORD is the same GitHub Actions
# secret Terraform used (via -var=mongo_app_password) to create the Mongo
# user in the first place. Paste its value in manually here.
$MONGO_APP_PASSWORD = "<the-MONGO_APP_PASSWORD-secret-value>"

kubectl apply -f k8s\namespace.yaml
kubectl create secret generic secure-todo-secrets `
  --namespace secure-todo `
  --from-literal=mongodb-uri="mongodb://todo_app:${MONGO_APP_PASSWORD}@${MONGO_IP}:27017/todo?authSource=todo" `
  --from-literal=user-name=todo-user `
  --from-literal=user-password="<long-random>" `
  --from-literal=admin-name=todo-admin `
  --from-literal=admin-password="<different-long-random>" `
  --dry-run=client -o yaml | kubectl apply -f -

# --- deploy ----------------------------------------------------------------
# No Kustomize: five flat manifests, applied directly, then the image is set.
kubectl apply -f k8s\namespace.yaml
kubectl apply -f k8s\
kubectl set image deployment/secure-todo "application=${ECR}:${TAG}" -n secure-todo

kubectl rollout status deployment/secure-todo -n secure-todo --timeout=5m
```

---

## 6. Demo — kubectl walkthrough

```powershell
# Cluster is in private subnets: every node IP is 10.20.1x.x, none public
kubectl get nodes -o wide

# Everything the exercise deploys
kubectl get all,serviceaccount -n secure-todo

# REQUIREMENT: wizexercise.txt exists in the RUNNING container
kubectl exec -n secure-todo deploy/secure-todo -- cat /app/wizexercise.txt

# REQUIREMENT: MongoDB access via a Kubernetes environment variable
kubectl exec -n secure-todo deploy/secure-todo -- printenv MONGODB_URI

# ...and where that value comes from
kubectl describe deploy secure-todo -n secure-todo | Select-String -Context 0,3 "secure-todo-secrets"

# REQUIREMENT: exposed via a Kubernetes ingress and CSP load balancer.
# Grab the ALB hostname the controller provisioned.
kubectl get ingress secure-todo -n secure-todo `
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# If ADDRESS stays empty, check the controller itself first, then the object
kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail=50
kubectl describe ingress secure-todo -n secure-todo

# App logs
kubectl logs -n secure-todo deploy/secure-todo --tail=50
```

### Prove the data is in the database

The point is independent proof, not just trusting the UI: add a todo through
the browser, then read it back a completely different way — straight out of
MongoDB, bypassing the app entirely.

```powershell
# 1. Open the app and add a todo with a distinctive title, e.g. "demo-proof-1"
kubectl get ingress secure-todo -n secure-todo `
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# ...paste that hostname into a browser, log in / register, add the todo

# 2. The DB password. No Secrets Manager -- it's the same MONGO_APP_PASSWORD
#    GitHub secret Terraform used to create this Mongo user in the first
#    place (GitHub -> Settings -> Secrets and variables -> Actions).
$MONGO_APP_PASSWORD = "<the-MONGO_APP_PASSWORD-secret-value>"

# 3. The database is NOT reachable from the internet or from your laptop --
#    only from EKS worker nodes (mongo_from_eks in mongodb.tf). Query it from
#    the VM itself instead. SSH works because port 22 is deliberately open
#    to 0.0.0.0/0 -- that's one of the exercise's required misconfigurations.
$MONGO_PUBLIC = aws ec2 describe-instances `
  --filters "Name=tag:Name,Values=sachin-app-mongodb" "Name=instance-state-name,Values=running" `
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
Write-Host "mongosh command to run once connected:"
Write-Host "mongosh `"mongodb://todo_app:${MONGO_APP_PASSWORD}@127.0.0.1:27017/todo?authSource=todo`" --eval 'db.todos.find().pretty()'"
ssh ec2-user@$MONGO_PUBLIC
```

```bash
# on the VM, paste the mongosh command printed above -- confirm the exact
# title you typed in the browser ("demo-proof-1") is in the result
mongosh "mongodb://todo_app:<MONGO_APP_PASSWORD-value>@127.0.0.1:27017/todo?authSource=todo" \
  --eval 'db.todos.find().pretty()'
```

**Alternative, no SSH needed** — same connection string, run from inside the
app pod itself instead of the VM (proves the pod's own env var is what's
actually talking to the database, not a second hardcoded path):

```powershell
# Confirms the running pod uses the exact URI the Secret injected
kubectl exec -n secure-todo deploy/secure-todo -- printenv MONGODB_URI
```

That alone doesn't query the data (the runtime image has no `mongosh`
client, by design — smaller attack surface), so pair it with the SSH/mongosh
step above for the actual proof of a stored document. If asked to skip SSH
entirely, be upfront that the trade-off is real: the only client available
without SSH is the app itself, and re-showing the same todo in the browser
is not independent proof.

---

## 7. Demo — security controls

```powershell
# --- PREVENTATIVE CONTROL: NetworkPolicy blocks it first ------------------
# Egress from this pod is restricted to MongoDB + DNS only (network-policy.yaml).
# This call to the Kubernetes API is neither, so it hangs and times out --
# the NetworkPolicy is the thing stopping the misconfiguration below from
# being reachable at all in normal operation.
kubectl exec -n secure-todo deploy/secure-todo -- sh -c `
  'wget -T 5 -qO- --no-check-certificate --header="Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" https://kubernetes.default.svc/api/v1/secrets | head -c 400'

# --- DELIBERATE MISCONFIGURATION: pod holds cluster-admin -----------------
kubectl auth can-i '*' '*' --as=system:serviceaccount:secure-todo:secure-todo
kubectl get clusterrolebinding secure-todo-cluster-admin -o yaml

# What that actually means: read every Secret in the cluster from inside the
# pod -- if this pod's egress weren't restricted, or an attacker reached the
# API server another way (a NetworkPolicy is defense in depth, not the only
# path in). Temporarily lift the policy to show the blast radius for real,
# then put it straight back.
kubectl delete -f k8s\network-policy.yaml
kubectl exec -n secure-todo deploy/secure-todo -- sh -c `
  'wget -qO- --no-check-certificate --header="Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" https://kubernetes.default.svc/api/v1/secrets | head -c 400'
kubectl apply -f k8s\network-policy.yaml

# --- DELIBERATE MISCONFIGURATION: public S3 backups ----------------------
$BUCKET = aws s3api list-buckets --query "Buckets[?starts_with(Name,'sachin-app-mongo-backups')].Name" --output text
curl "https://$BUCKET.s3.<your AWS_REGION>.amazonaws.com/"          # anonymous listing works
aws s3 ls "s3://$BUCKET/daily/" --no-sign-request           # ...and so does this

# --- DELIBERATE MISCONFIGURATION: SSH open to the world ------------------
aws ec2 describe-security-groups --filters "Name=group-name,Values=sachin-app-mongo" `
  --query 'SecurityGroups[0].IpPermissions'

# --- PREVENTATIVE CONTROL: Pod Security Admission ------------------------
# Rejected by the API server at admission time, not reported afterwards
kubectl -n secure-todo run bad --image=busybox --privileged -- sleep 300

# --- PREVENTATIVE CONTROL: NetworkPolicy egress restriction --------------
# Times out -- the private subnets do have a route out now (NAT gateway),
# but the app pod's NetworkPolicy only permits MongoDB + DNS egress,
# enforced by the VPC CNI's eBPF agent. This is now the only layer
# stopping it (there used to be a second, redundant layer when private
# subnets had no route out at all -- see README's "NAT gateway, single AZ").
kubectl exec -n secure-todo deploy/secure-todo -- wget -T 5 -qO- https://example.com

# ...while AWS API access still works fine, through the NAT gateway
kubectl get pods -n secure-todo    # this command itself proves EKS API reachability
aws ec2 describe-nat-gateways --filter "Name=tag:Name,Values=sachin-app-nat" `
  --query 'NatGateways[].[NatGatewayId,State]' --output table

# --- AUDIT: EKS control plane logging ------------------------------------
aws logs describe-log-streams --log-group-name /aws/eks/sachin-app-cluster/cluster `
  --order-by LastEventTime --descending --max-items 5

# --- DETECTIVE: Security Hub (the one screen to show the panel) ----------
aws securityhub get-findings `
  --filters '{"SeverityLabel":[{"Value":"CRITICAL","Comparison":"EQUALS"},{"Value":"HIGH","Comparison":"EQUALS"}],"RecordState":[{"Value":"ACTIVE","Comparison":"EQUALS"}]}' `
  --query 'Findings[].[Title,Resources[0].Id]' --output table --max-items 20
```

---

## 7b. Demo — simulated attack & audit log detection

The PDF's "Optional Simulation" bullet: run an attacker-style action and show a
preventative or detective control actually respond to it, not just "the
service is enabled." Two beats, each a few seconds of real command output.

```powershell
# --- ATTACK 1: reach the internet from inside the app pod (prevention) ---
# Same command as §7's NetworkPolicy proof, called out here as its own
# beat: this isn't just a rule on paper, it's an actual attacker move (pod
# compromised -> phone home / pull a second-stage payload) failing for
# real. The private subnets do have a route out (NAT gateway) now, so this
# depends entirely on the NetworkPolicy actually being applied and
# enforced -- confirm that first with the aws-network-policy-agent check in
# §10's troubleshooting table if this unexpectedly succeeds.
kubectl exec -n secure-todo deploy/secure-todo -- wget -T 5 -qO- https://example.com
# Expect: timeout, no response. Contrast with the MongoDB connection, which
# works fine (same pod, different destination) -- proves it's a deliberate
# restriction, not a broken network.

# --- ATTACK 2: create a static IAM access key (persistence), then find it
#     in CloudTrail (detection) -----------------------------------------
# Every credential in this pipeline is OIDC-issued and short-lived on
# purpose (bootstrap's GitHub OIDC role, the ALB controller's IRSA role) --
# nothing here is ever supposed to create a static access key. This
# simulates someone doing it anyway, e.g. after gaining console access, and
# shows the exact CloudTrail event that would catch it.
aws iam create-user --user-name demo-attack-sim
aws iam create-access-key --user-name demo-attack-sim | Out-Null

# CloudTrail's API (not just the 90-second-delayed console view) usually
# surfaces the event within a minute or so.
aws cloudtrail lookup-events `
  --lookup-attributes AttributeKey=EventName,AttributeValue=CreateAccessKey `
  --max-results 5 `
  --query 'Events[].[EventTime,Username,CloudTrailEvent]' --output table

# Clean up immediately -- don't leave a live static credential sitting in
# the account after the demo.
$KEY = aws iam list-access-keys --user-name demo-attack-sim --query 'AccessKeyMetadata[0].AccessKeyId' --output text
aws iam delete-access-key --user-name demo-attack-sim --access-key-id $KEY
aws iam delete-user --user-name demo-attack-sim

# --- BONUS: the backups bucket's own public-access change, on record ----
# The bucket didn't drift into being public -- it was made public on
# purpose by Terraform. CloudTrail has that exact moment too, which is a
# good answer if asked "how would you know when/how this became public":
aws cloudtrail lookup-events `
  --lookup-attributes AttributeKey=EventName,AttributeValue=PutBucketPolicy `
  --max-results 10 `
  --query 'Events[].[EventTime,Username,Resources[0].ResourceName]' --output table
```

## 8. Demo — "point the app at a new database" and prove the pipeline redeploys

Two curveballs the panel may throw that nothing above rehearses directly:
(a) "connect the app to a new database and run it", and (b) "show me the
GitHub pipeline picking up a change". Rehearse both once, end to end, before
the real demo — the timings below are estimates, not guarantees.

### 8a. Fast path — prove the pipeline redeploys on a code change (~5 min)

The safe, always-works answer to "show the pipeline working with an update".
Doesn't touch the database at all — use this if time is short or 8b is too
risky to attempt live.

```powershell
# 1. Trivial, visible, safe change
#    src/main/resources/templates/todos.html, line 27:
#    <h1>Make space for what matters.</h1>  -->  anything else
git add -A
git commit -m "demo: tweak headline"
git push

# 2. GitHub -> Actions -> watch "Application (build, scan, deploy)" run:
#    tests -> build -> Trivy scan -> push -> kubectl set image -> rollout

# 3. New revision, tagged with the commit's short SHA
kubectl rollout history deployment/secure-todo -n secure-todo

# 4. Refresh the browser at the ALB hostname -- new headline is live
```

### 8b. Real path — a genuinely different database (~10-15 min, rehearse first)

**Why this can't be faked with a quick `mongosh` command:** `todo_app` is the
only MongoDB user ever created (`mongo-userdata.sh.tftpl`), and creating it
permanently closed MongoDB's "localhost exception" — the only mechanism that
lets you create users without already having credentials. There is no
admin/root account on this VM, and `todo_app` itself only has `readWrite` on
`todo`, not `userAdmin` anywhere. So there is no live command that stands up
a second database with its own scoped user; the only clean way is a fresh
VM, which means going through Terraform. This is a real answer if asked "why
not just add a user live" — not a dodge.

```powershell
# 1. Two one-line edits, same new database name in both:
#    infra/terraform/mongodb.tf   ~line 189: database_name = "todo"  -> "todo2"
#    .github/workflows/app.yml    ~line 171: .../todo?authSource=todo -> .../todo2?authSource=todo2
git add infra/terraform/mongodb.tf .github/workflows/app.yml
git commit -m "demo: point at a new database"
git push
# Both infra.yml and app.yml will queue on this one commit -- that's fine,
# just don't trust app.yml's first run; it may race ahead of infra.yml.

# 2. Watch infra.yml (Actions -> Infrastructure) run to completion first.
#    mongodb.tf sets user_data_replace_on_change = true, so Terraform
#    destroys and recreates the Mongo EC2 instance: fresh disk, fresh
#    MongoDB install, userdata creates todo_app fresh with readWrite on
#    todo2 this time.

# 3. Only once infra.yml is green, (re-)run the app pipeline:
#    Actions -> Application (build, scan, deploy) -> Run workflow

# 4. Prove it the same two ways as the original requirement
kubectl exec -n secure-todo deploy/secure-todo -- printenv MONGODB_URI
# ...ends in /todo2?authSource=todo2

# Add a todo in the browser, then from the Mongo VM:
mongosh "mongodb://todo_app:<MONGO_APP_PASSWORD-value>@127.0.0.1:27017/todo2?authSource=todo2" `
  --eval 'db.todos.find().pretty()'

# 5. Afterwards: revert both files (or re-apply with "todo") so the repo
#    isn't left pointing at a throwaway database name.
```

---

## 9. Teardown

Order matters. The ALB is created by the AWS Load Balancer Controller in
response to the Ingress object, not by Terraform, so Terraform doesn't know
it exists and can't delete it — the VPC destroy will hang on its ENIs if you
skip step 1.

```powershell
# 1. Delete the Ingress first and wait for it -- this is what tells the
#    controller to actually delete the ALB via the AWS API
kubectl delete -f k8s\ingress.yaml

# 2. Now the rest of the app + the controller itself
kubectl delete -f k8s\

# 3. Destroy the infrastructure
#    Actions -> Infrastructure (Terraform) -> Run workflow -> destroy
#    or locally:
cd infra\terraform
terraform destroy -var="ssh_public_key=<your-public-key>"
cd ..\..

# 4. Optional: remove the bootstrap resources too
cd infra\bootstrap
terraform destroy -var="github_repository=<owner>/<repo>"
cd ..\..
```

---

## 10. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `docker compose up` fails on MongoDB startup | An old `mongo:8.0` volume. Run `docker compose down -v`. |
| `terraform apply` fails on Security Hub | Already enabled in the account+region — it's a singleton. Set `enable_security_hub=false`. |
| `terraform apply` fails on the EKS version | `kubernetes_version` no longer supported. Check `aws eks describe-cluster-versions --region <your AWS_REGION>` and update the variable. |
| Ingress `ADDRESS` stays empty after 5 min | Check the controller pod first: `kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail=50`. Common causes: the ServiceAccount's `eks.amazonaws.com/role-arn` annotation never got patched in (check `kubectl get sa aws-load-balancer-controller -n kube-system -o yaml`), or public subnets missing the `kubernetes.io/role/elb=1` tag (they shouldn't be, `network.tf` sets it). |
| Controller pod stuck `CrashLoopBackOff` or logs show `AccessDenied` | IRSA isn't wired up right — confirm the ServiceAccount annotation has a real role ARN, not `REPLACED_BY_PIPELINE`, and that `infra/terraform/alb-controller.tf`'s IAM policy actually applied (`aws iam get-role-policy` / `list-attached-role-policies` on `sachin-app-alb-controller`). |
| App unreachable even though the ALB has a hostname | Target type is `ip` (`k8s/ingress.yaml`), so the controller manages its own backend security group rules via IAM — check `kubectl describe targetgroupbindings.elbv2.k8s.aws -n secure-todo` for unhealthy targets before assuming it's a networking gap to fix by hand. |
| Nodes stuck `NotReady`, or pods stuck `ImagePullBackOff` | Image pulls depend on the single NAT gateway for ECR/EKS/EC2 API reachability. Check `aws ec2 describe-nat-gateways` shows `available`, and that `aws_nat_gateway.main` finished applying *before* the node group tried to launch (see the `depends_on` in `eks.tf`). |
| Pod stuck `CrashLoopBackOff` | Usually MongoDB unreachable. `kubectl logs -n secure-todo deploy/secure-todo` and confirm the VM is running and the security group allows 27017 from the cluster SG. |
| App can't reach MongoDB even though the security group + VM look fine | Check `k8s/network-policy.yaml` applied AND that `enableNetworkPolicy` actually took on the vpc-cni addon: `kubectl get daemonset aws-node -n kube-system -o jsonpath='{.spec.template.spec.containers[*].name}'` should list `aws-network-policy-agent`. If it's missing, the addon's `configuration_values` in `eks.tf` didn't apply — re-run `terraform apply`. |
| `terraform apply` fails with a MongoDB user-creation error mid-boot | `var.mongo_app_password` is empty or wasn't passed. Confirm the `MONGO_APP_PASSWORD` GitHub secret exists in the `aws` environment, or pass `-var="mongo_app_password=..."` manually. |
| `docker push` rejected | ECR tags are immutable by design. Use a new tag. |
| `kubectl` says `Unauthorized` | Your IAM principal has no EKS access entry. Set `cluster_admin_role_arn` and re-apply, or use the role that created the cluster. |
| App reachable but no todos persist | Check `MONGODB_URI` in the Secret and that `authSource=todo` is present. |
| `app.yml` fails at "Discover infrastructure" right after the first push | Expected — see §1f. `infra.yml` hasn't finished yet. Wait for it, then re-run `app.yml`. |
| `git status` shows `k8s-rendered-preview.yaml` as untracked after §1e | Harmless scratch file from the dry-run preview; delete it or leave it — it's not something the pipeline reads. |
