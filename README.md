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

- The database credentials (`DB_USER`, `DB_PASSWORD`, `POSTGRES_USER`, `POSTGRES_PASSWORD`) exist in Git **only** as `SealedSecret`s: `platform/dev/tasktracker-credentials.sealed.yaml` and `platform/staging/tasktracker-credentials.sealed.yaml`. Dev and staging use different passwords and are sealed separately.
- They are encrypted with `kubeseal` against the public key of this cluster's Sealed Secrets controller. The plaintext input was typed into `secrets-plain/<env>.env` in an editor (never on the command line), piped through `kubectl create secret --dry-run=client | kubeseal` so the plaintext Secret never reached disk, and deleted after sealing; the values are kept in a password manager.
- The controller (installed by `argocd/applications/sealed-secrets.yaml`) decrypts each SealedSecret into the Secret `tasktracker-credentials`, which the chart reads through `existingSecret` (it never renders a Secret itself).
- The controller's private sealing key is backed up **outside** the repository at `../dso202-keys/sealing-key.backup.yaml` (mode 600) and restored before the controller starts on a rebuild (Task 9).
- `.gitignore` excludes key material and plaintext inputs, but the proof is the history search in `docs/evidence.md` (Task 4): no credential value, plain or base64, appears in any commit.

## Answers

### Q1 (Task 3)
**Why `platform` is applied by hand but `dso202` comes from the root.** The root Application must belong to a project, and that project must exist before the root can be created: Argo CD cannot deliver the project that authorises its own delivery. `platform` is therefore part of the hand-applied bootstrap (with the root itself), and it is the only project allowed to target the `argocd` namespace, which is where Application and AppProject objects live. Once the root exists, every *other* Argo CD object is ordinary desired state: `dso202` is a file in `argocd/projects/`, so it is versioned, reviewed through Git and recreated automatically on a rebuild, which is shown by `dso202` appearing in the resource list of `argocd app get root` (evidence, Task 3).

**Risk if `dso202` could deploy into `argocd`.** Applications and AppProjects are just objects in the `argocd` namespace. A workload Application allowed to write there could commit an Application that names `project: platform`, or edit the `dso202` AppProject itself, and so escape its own whitelist: create Namespaces, ClusterRoles, quotas, or anything else cluster-wide. Write access to the `argocd` namespace is effectively Argo CD administrator access, so a mistaken or malicious commit to the chart would no longer be contained by the project boundary (least privilege would be lost).

### Q2 (Task 4)
**What strict scope prevents.** With the default *strict* scope, the SealedSecret's name and namespace are mixed into the encryption, so the ciphertext decrypts only as `tasktracker-credentials` in the namespace it was sealed for. Someone who can create objects in another namespace cannot copy the committed file there (or rename it) to make the controller decrypt the dev password into a Secret they can read; this is also why dev and staging are sealed separately and a dev file is useless in `dso202-staging`.

**If the sealing key is lost.** Every SealedSecret in the repository becomes permanent ciphertext: nobody, including the owner, can decrypt it, and a new cluster's controller generates a different key, so the platform Applications report `Degraded` with `no key could decrypt secret`. The Secrets already running in a live cluster still work, but nothing can be rebuilt from Git. Recovery: take the plaintext values from the password manager (or, if they are lost too, rotate the credentials, which for an initialised database also means changing the password inside Postgres), seal them again against the new controller's public key, commit the new SealedSecrets, and immediately back up the new key outside the repository. Because the controller also renews its key every 30 days, the backup must be repeated after each renewal and after every rebuild.

### Q3 (Task 5)
**Difference.** *Synced* is a comparison: the live objects equal what Git renders for the target revision. *Healthy* is an assessment of whether those objects actually work (a Deployment has its replicas available, a StatefulSet has finished rolling, a Job succeeded). They are independent: Argo CD can apply exactly what Git says (Synced) while the result is still starting, or broken (Progressing/Degraded); and a working system can drift from Git (Healthy but OutOfSync).

**Example from this task** (`docs/evidence.md`, 5.2, `kubectl get applications -n argocd -w`):
```text
08:23:04 tasktracker-dev       Synced        Progressing
08:23:09 tasktracker-dev       Synced        Healthy
```
At 08:23:04 every manifest had been applied (Synced), but the frontend Pod created in wave 2 was not yet ready (`tasktracker-frontend ... 0/1 Running` at 08:23:04 in the Pod watch), so health was `Progressing` until its readiness probe passed at 08:23:09. A lasting case is provoked in Task 7: setting the backend tag to `1.1` is applied successfully (Synced to the new commit), but the new Pod never becomes ready, and after `progressDeadlineSeconds: 120` the Application reports `Synced` and `Degraded`.

### Q4 (Task 6)
**Argo CD RBAC** controls what a user of *Argo CD* (UI, CLI or API) may do with Argo CD objects: view, sync, delete or override Applications, read Projects, read Pod logs, and so on (`p, reviewer, applications, get, dso202/*, allow`). It is configured in the `argocd-rbac-cm` ConfigMap (`policy.csv`, `policy.default`), here in `bootstrap/argocd/argocd-rbac-cm-patch.yaml`, and its users are declared in `argocd-cm` (`accounts.reviewer: login`). The actions are then carried out by Argo CD's own service accounts, so a `reviewer` never needs any Kubernetes permission.

**Kubernetes RBAC** (Assignment 2) controls what an identity that talks *directly to the Kubernetes API* may do with Kubernetes objects: for example the `dso202-developers` group may `get/list/watch` Pods and logs in `dso202-dev` (`platform/dev/rbac.yaml`). It is configured with Role/ClusterRole and RoleBinding/ClusterRoleBinding objects in the cluster, and it also bounds Argo CD itself (the application controller's ClusterRole is what lets it create objects at all).

The two are independent: `reviewer` can read Pod logs through Argo CD without any Kubernetes RoleBinding, and a member of `dso202-developers` can run `kubectl logs` without any Argo CD account.

**With SSO** (Dex or OIDC connected to the organisation's identity provider), local accounts such as `accounts.reviewer` would be removed, and `policy.csv` would grant permissions to *groups* from the identity provider's token instead of to individual local users, usually through roles:
```text
p, role:dso202-reviewer, applications, get, dso202/*, allow
p, role:dso202-reviewer, projects,     get, dso202,   allow
p, role:dso202-reviewer, logs,         get, dso202/*, allow
g, my-org:dso202-reviewers, role:dso202-reviewer
```
Membership would then be managed in the identity provider (joining or leaving the group), not in Git, and `scopes` in `argocd-rbac-cm` would name the token claim that carries the groups (by default `[groups]`).

### Q5 (Task 7)
_To be written._

### Q6 (Task 9)
_To be written._
