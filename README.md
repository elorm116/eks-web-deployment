# EKS Web Deployment

Production-grade Kubernetes deployment on Amazon EKS, built with Terraform.

## Architecture

```
Internet
    │
    ▼
AWS Load Balancer (ELB)
    │  provisioned automatically by Kubernetes
    ▼
Service (LoadBalancer) — stable endpoint
    │  routes to healthy pods only
    ├── Pod 1 (nginx:alpine)
    ├── Pod 2 (nginx:alpine)
    └── Pod 3 (nginx:alpine)
          │
          └── ConfigMap (HTML content)

Infrastructure (Terraform):
  VPC → private subnets → EKS cluster → managed node group (2x t3.small)
```

## Stack

- **Terraform** — infrastructure provisioning
- **Amazon EKS** — managed Kubernetes control plane
- **EC2 Managed Node Group** — worker nodes
- **AWS Load Balancer** — external traffic entry point
- **nginx:alpine** — web server
- **VPC CNI** — pod networking

## Project structure

```
eks-web-deployment/
├── vpc.tf           # VPC, subnets, NAT gateway
├── eks.tf           # EKS cluster + addons + node group
├── outputs.tf       # cluster endpoint, kubectl command
├── variables.tf     # region, cluster name, instance type
├── provider.tf      # AWS provider
└── k8s/
    ├── configmap.yaml   # HTML content
    ├── deployment.yaml  # 3 replicas, probes, limits
    ├── service.yaml     # LoadBalancer — provisions real ELB
    └── ingress.yaml     # hostname-based routing
```

## Deploy

### Prerequisites

- Terraform >= 1.0
- AWS CLI configured (`aws sts get-caller-identity`)
- kubectl installed

### 1. Provision infrastructure

```bash
terraform init
terraform plan
terraform apply
```

Takes 15-20 minutes. EKS control plane takes ~10 min, node group ~5 min.

### 2. Configure kubectl

```bash
aws eks update-kubeconfig --region us-east-1 --name web-eks
kubectl get nodes
```

### 3. Deploy the app

```bash
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
```

### 4. Get the Load Balancer URL

```bash
kubectl get svc web
# EXTERNAL-IP column shows the ELB DNS name
# Takes 60-90 seconds to provision
```

### 5. Hit your app

```bash
curl http://<elb-dns-name>
```

## Zero-downtime updates

Update content without downtime:

```bash
# Edit k8s/configmap.yaml
kubectl apply -f k8s/configmap.yaml
kubectl rollout restart deployment web
kubectl rollout status deployment web
```

Kubernetes replaces pods one at a time. Traffic keeps flowing throughout.

## Self-healing demo

```bash
kubectl delete pods --all
kubectl get pods -w
# New pods appear in seconds
```

## Tear down

```bash
# Delete Kubernetes resources first (removes the ELB)
kubectl delete -f k8s/

# Then destroy infrastructure
terraform destroy
```

**Always delete k8s resources before terraform destroy** — otherwise the ELB stays alive and blocks VPC deletion.

## Troubleshooting

### Nodes stuck NotReady after apply

**Symptom:** `kubectl get nodes` shows NotReady, `kubectl get pods -n kube-system` shows nothing.

**Cause:** VPC CNI addon not installed before nodes tried to join.

**Fix:**
```bash
aws eks create-addon --cluster-name web-eks --addon-name vpc-cni --region us-east-1
aws eks create-addon --cluster-name web-eks --addon-name kube-proxy --region us-east-1
aws eks create-addon --cluster-name web-eks --addon-name coredns --region us-east-1
```

**Prevention:** Always include `before_compute = true` on vpc-cni in your EKS module:
```hcl
cluster_addons = {
  vpc-cni = { before_compute = true }
}
```

---

### kubectl returns "must be logged in to server"

**Symptom:** All kubectl commands fail with credentials error after `terraform apply`.

**Cause:** EKS module v20 uses access entries, not the old aws-auth ConfigMap. Your IAM user needs an explicit access entry.

**Fix:**
```bash
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
```

**Prevention:** Add to eks.tf:
```hcl
enable_cluster_creator_admin_permissions = true
```

---

### Node group CREATE_FAILED

**Symptom:** `aws eks describe-nodegroup` shows `CREATE_FAILED` with `NodeCreationFailure`.

**Cause:** Nodes launched but couldn't register — usually CNI not ready or IAM role missing policies.

**Diagnosis:**
```bash
kubectl describe node <node-name> | grep -A5 "Conditions"
# Look for: "cni plugin not initialized"

aws iam list-attached-role-policies --role-name <node-role-name>
# Should have: AmazonEKSWorkerNodePolicy, AmazonEKS_CNI_Policy, AmazonEC2ContainerRegistryReadOnly
```

---

### ELB DNS not resolving immediately

**Symptom:** `curl` returns empty after `kubectl apply -f k8s/service.yaml`.

**Cause:** AWS ELB DNS propagation takes 2-3 minutes.

**Fix:** Wait 2-3 minutes then retry. Check status:
```bash
kubectl get svc web -w
# Wait for EXTERNAL-IP to show the DNS name

nslookup <elb-dns-name>
# Wait until this returns an IP
```

---

### terraform destroy hangs on VPC deletion

**Symptom:** `terraform destroy` gets stuck deleting the VPC.

**Cause:** The ELB created by the LoadBalancer service is still alive and attached to the VPC. Terraform doesn't know about it because kubectl created it.

**Fix:** Always delete Kubernetes resources before destroying infrastructure:
```bash
kubectl delete -f k8s/
# Wait 60 seconds for ELB to de-provision
terraform destroy
```

## Related projects

- [k8s-web-deployment](https://github.com/elorm116/k8s-web-deployment) — same app on a local Kubernetes cluster (Killercoda). Good for understanding Kubernetes concepts without cloud costs.
- [Terraform 30 Days Challenge](https://github.com/elorm116) — includes multi-region HA on EC2 + ASG + ALB + RDS. The traditional AWS approach to the same problem this project solves with Kubernetes.
