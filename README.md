<!--
=============================================================================
File        : README.md
Assignment  : DSO202 Assignment 4
Descriptor  : Section 11 - submission requirements
Purpose     : What this repository is, the pinned versions, how to build the
              whole environment from an empty machine, cleanup, credential
              handling, and the written answers Q1-Q6.
=============================================================================
-->
# dso202-gitops

GitOps delivery of the three-tier Task Tracker (PostgreSQL database, Node.js backend, nginx frontend) to two environments, `dev` and `staging`, with Argo CD. After a two-step bootstrap, nothing reaches the cluster except through this repository: Argo CD, running inside the cluster, polls it and makes the cluster match it.

| Environment | Namespace | Follows | Sync | Frontend | Backend API (called by the browser) |
|---|---|---|---|---|---|
| dev | `dso202-dev` | branch `main` | automated, prune, self-heal | http://localhost:30080 | http://localhost:30090 |
| staging | `dso202-staging` | a Git tag (`v1.x.0`) | manual | port-forward → http://localhost:8081 | port-forward → http://localhost:8091 |

## Repository layout

```text
bootstrap/argocd/   Argo CD itself (Kustomize over the pinned upstream manifest) - applied by hand
bootstrap/root/     platform AppProject + root Application                     - applied by hand
argocd/             every other AppProject and Application (watched by root)   - delivered from Git
platform/<env>/     namespace, quota, limits, RBAC, sealed credentials         - delivered from Git
charts/tasktracker/ the Helm chart, identical in both environments
environments/<env>/ the only place where environments differ
cluster/            kind configuration
docs/evidence.md    command output for every task
```

## Pinned versions

| Component | Version |
|---|---|
| Argo CD / `argocd` CLI | v3.5.6 |
| Sealed Secrets chart / controller / `kubeseal` | 2.20.0 / 0.40.0 / v0.40.0 |
| kind / node image / kubectl | v0.20.0 / `kindest/node:v1.36.1` (pinned by digest) / v1.34.1 |
| Helm | v4.3.0 |
| Application images | `rynorbu11/dso202-{db,backend,frontend}` tags `1.0` and `1.1` only |
| Smoke-test image | `busybox:1.37` |

## Build from an empty machine

Prerequisites: Docker, kind, kubectl, Helm, git, `argocd` v3.5.6 and `kubeseal` v0.40.0 installed; the sealing-key backup at `../dso202-keys/sealing-key.backup.yaml`.

```bash
# 1. Repository and cluster
git clone https://github.com/Khemraj9815/dso202-gitops.git
cd dso202-gitops
kind create cluster --name dso202-gitops --config cluster/kind-cluster.yaml

# 2. Restore the sealing key BEFORE the controller exists, so it does not generate a new one
kubectl create namespace sealed-secrets
kubectl apply -f ../dso202-keys/sealing-key.backup.yaml

# 3. Bootstrap step 1: Argo CD (server-side apply: the ApplicationSet CRD is too large for client-side apply)
kubectl apply -k bootstrap/argocd --server-side --force-conflicts
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s

# 4. Bootstrap step 2: platform project + root Application. Nothing else is applied by hand.
kubectl apply -f bootstrap/root
kubectl get applications -n argocd -w        # waves -3, -2, -1, 0 become Healthy in order

# 5. Sign in (port-forward in its own terminal) and release the staging gate
kubectl port-forward svc/argocd-server -n argocd 8080:443
argocd admin initial-password -n argocd
argocd login localhost:8080 --username admin --insecure
argocd app sync tasktracker-staging

# 6. Reach staging
kubectl port-forward -n dso202-staging svc/tasktracker-frontend 8081:80
kubectl port-forward -n dso202-staging svc/tasktracker-backend 8091:8080
```

## Cleanup

```bash
kind delete cluster --name dso202-gitops
```

The sealing-key backup in `../dso202-keys/` is kept: without it, every SealedSecret in this repository is unreadable on a new cluster.

## Credential handling

_Completed in Task 4._

## Answers

### Q1 (Task 3)
_To be written._

### Q2 (Task 4)
_To be written._

### Q3 (Task 5)
_To be written._

### Q4 (Task 6)
_To be written._

### Q5 (Task 7)
_To be written._

### Q6 (Task 9)
_To be written._
