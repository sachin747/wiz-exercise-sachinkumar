# One-time render step. Produces k8s/alb-controller.yaml from the real,
# upstream AWS Load Balancer Controller Helm chart -- this is NOT hand
# written, because the chart generates a self-signed webhook TLS cert at
# render time (Helm's genSelfSignedCert), which is not something safe to
# fabricate by hand. Uses Docker to run Helm so nothing needs to be
# installed on this machine beyond Docker, which is already here.
#
# Chart version is pinned to 1.13.0 (controller v2.13.0) to match the IAM
# policy already copied into infra/terraform/files/alb-controller-iam-policy.json
# -- if you ever bump the chart version, re-copy that policy file too.
#
# Safe to re-run any time the chart version changes; it fully overwrites
# k8s/alb-controller.yaml.

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

Write-Host "=== Rendering AWS Load Balancer Controller v1.13.0 chart via Docker+Helm ==="

docker run --rm --entrypoint sh -v "${PWD}\k8s:/out" alpine/helm:latest -c "
  helm repo add eks https://aws.github.io/eks-charts &&
  helm repo update &&
  helm template aws-load-balancer-controller eks/aws-load-balancer-controller \
    --version 1.13.0 \
    --namespace kube-system \
    --include-crds \
    --set clusterName=sachin-app-cluster \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
  > /out/alb-controller.yaml
"

if ($LASTEXITCODE -ne 0) {
    Write-Host "=== RENDER FAILED ==="
    exit 1
}

Write-Host ""
Write-Host "=== Render OK. First 20 lines: ==="
Get-Content k8s\alb-controller.yaml -TotalCount 20
Write-Host ""
Write-Host "Total lines: $((Get-Content k8s\alb-controller.yaml).Count)"
Write-Host "=== DONE ==="
