# EKS Web Deployment

Production-grade Kubernetes deployment on Amazon EKS. Infrastructure provisioned with Terraform. App deployed and managed with ArgoCD GitOps. Multi-environment support with Kustomize overlays.

## Architecture

```
GitHub (source of truth)
    │
    └── argocd-apps/
            └── root-app.yaml   ← applied once manually, never again
                    │
                    ▼  ArgoCD reads this folder
            web-app.yaml        ← ArgoCD creates web Application automatically
                    │
                    ▼  points at
            k8s/overlays/prod/  ← Kustomize merges base + prod patches
                    │
                    ▼
            EKS Cluster         ← 3 pods, LoadBalancer
                    │
                    ▼
            AWS ELB             ← real public URL
```

## Stack

- **Terraform** — EKS cluster + VPC provisioning
- **ArgoCD** — GitOps continuous delivery
- **Kustomize** — multi-environment configuration
- **Amazon EKS** — managed Kubernetes
- **AWS Load Balancer** — external traffic
- **nginx:alpine** — web server

## Project structure

```
eks-web-deployment/
├── terraform/
│   ├── eks.tf                  # EKS cluster + addons + node group
│   ├── vpc.tf                  # VPC, subnets, NAT gateway
│   ├── variables.tf            # region, cluster name, instance type
│   ├── outputs.tf              # cluster endpoint, kubectl command
│   └── provider.tf             # AWS provider
├── argocd-apps/                # App of Apps — ArgoCD manages these
│   ├── root-app.yaml           # Root Application (applied once manually)
│   └── web-app.yaml            # Web Application (created by ArgoCD)
└── k8s/
    ├── base/                   # Shared base manifests
    │   ├── deployment.yaml     # 3 replicas, probes, resource limits
    │   ├── service.yaml        # Service definition
    │   ├── configmap.yaml      # HTML content
    │   ├── ingress.yaml        # Ingress rules
    │   └── kustomization.yaml  # Lists base resources
    └── overlays/
        ├── staging/            # Staging patches (1 replica, ClusterIP)
        │   └── kustomization.yaml
        └── prod/               # Prod patches (3 replicas, LoadBalancer)
            └── kustomization.yaml
```

## How to deploy

### Prerequisites

- Terraform >= 1.0
- AWS CLI configured
- kubectl installed
- ArgoCD CLI installed (`brew install argocd`)

### 1. Provision infrastructure

```bash
terraform init
terraform plan
terraform apply
```

Takes 15-20 minutes. EKS control plane ~10 min, node group ~5 min.

### 2. Configure kubectl + grant IAM access

```bash
aws eks update-kubeconfig --region us-east-1 --name web-eks

aws eks create-access-entry \
  --cluster-name web-eks \
  --principal-arn $(aws sts get-caller-identity --query Arn --output text) \
  --region us-east-1

aws eks associate-access-policy \
  --cluster-name web-eks \
  --principal-arn $(aws sts get-caller-identity --query Arn --output text) \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster \
  --region us-east-1

kubectl get nodes
```

### 3. Install ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=argocd-server \
  -n argocd --timeout=120s
```

### 4. Login to ArgoCD

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

argocd login localhost:8080 \
  --username admin \
  --password $(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d) \
  --insecure
```

### 5. Apply root app — one time only

```bash
kubectl apply -f argocd-apps/root-app.yaml
```

ArgoCD reads `argocd-apps/` from GitHub and creates the `web` Application automatically. You never run `argocd app create` again.

### 6. Verify

```bash
kubectl get app -n argocd
kubectl get pods
kubectl get svc web

# Get ELB URL
kubectl get svc web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

## GitOps workflow

### Deploy a change

```bash
# Edit any file in k8s/base/ or k8s/overlays/
vim k8s/base/configmap.yaml

git add .
git commit -m "feat: update content"
git push origin main

# ArgoCD detects the new commit and deploys automatically
# Force sync if you don't want to wait 3 minutes
argocd app sync root
argocd app sync web
```

### Rollback

```bash
# Find the commit to revert to
git log --oneline

# Revert
git revert <bad-commit-hash>
git push origin main

# ArgoCD deploys the reverted state automatically
```

## Kustomize overlays

### Preview what an overlay generates

```bash
# See final prod YAML (base + patches merged)
kubectl kustomize k8s/overlays/prod

# See final staging YAML
kubectl kustomize k8s/overlays/staging
```

### What each overlay changes

| Setting | Base | Staging | Production |
|---------|------|---------|------------|
| Replicas | 3 | 1 | 3 |
| Memory limit | 64Mi | 32Mi | 64Mi |
| Service type | ClusterIP | ClusterIP | LoadBalancer |

## App of Apps pattern

```
root-app.yaml (applied manually once)
    │
    └── watches argocd-apps/ folder in GitHub
              │
              ├── web-app.yaml     → creates web Application
              ├── api-app.yaml     → creates api Application (future)
              └── monitoring.yaml  → creates monitoring Application (future)
```

Add a new service: create a new YAML file in `argocd-apps/`. ArgoCD picks it up automatically. No manual CLI commands.

## Self-healing demo

```bash
# Manually break it — scale to 1 replica bypassing Git
kubectl scale deployment web --replicas=1

# ArgoCD detects drift (Git says 3, cluster has 1)
# Automatically restores to 3 within 3 minutes
# Or force it:
argocd app sync web

kubectl get pods  # back to 3
```

## Tear down — order matters

```bash
# Step 1: delete ArgoCD apps (removes ELB)
kubectl delete -f argocd-apps/root-app.yaml
kubectl delete app web -n argocd 2>/dev/null || true
sleep 60

# Step 2: destroy infrastructure
terraform destroy
```

Always delete Kubernetes resources before `terraform destroy`. The LoadBalancer service creates an AWS ELB — if Terraform destroys the VPC first, the ELB blocks deletion.

## Troubleshooting

### Nodes NotReady after apply

```bash
# Check why
kubectl describe node <node-name> | grep -A5 "Conditions"
# Look for: "cni plugin not initialized"

# Fix: install CNI manually
aws eks create-addon --cluster-name web-eks --addon-name vpc-cni --region us-east-1
aws eks create-addon --cluster-name web-eks --addon-name kube-proxy --region us-east-1
aws eks create-addon --cluster-name web-eks --addon-name coredns --region us-east-1
```

Prevention: `vpc-cni` must have `before_compute = true` in eks.tf.

---

### kubectl returns Unauthorized

```bash
# Grant IAM access (see step 2 above)
aws eks create-access-entry ...
aws eks associate-access-policy ...
```

Prevention: add `enable_cluster_creator_admin_permissions = true` to eks.tf.

---

### ArgoCD not picking up new commits

```bash
# Check what commit ArgoCD is on
argocd app get web | grep "Sync Revision"

# Check what's actually on GitHub
git ls-remote https://github.com/elorm116/eks-web-deployment HEAD

# Force sync
argocd app sync web
```

Common cause: ArgoCD was pointing at wrong repo or wrong path.

---

### terraform destroy hangs on VPC

ArgoCD or kubectl created an ELB that Terraform doesn't know about. Delete k8s resources first, wait 60 seconds, then destroy.

---

### ArgoCD app stuck Progressing

```bash
kubectl get pods -n argocd
kubectl describe app web -n argocd | grep -A10 "Conditions"
kubectl get events -n default --sort-by='.lastTimestamp'
```

Usually a pod that won't start — check events for the real error.

## Related projects

- [Terraform 30-day challenge](https://github.com/elorm116) — multi-region HA on EC2 + ASG + ALB + RDS (Day 27)
- [k8s-web-deployment](https://github.com/elorm116/k8s-web-deployment) — same app on Killercoda, Kubernetes fundamentals
