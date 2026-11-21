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

## Status
Tasks 1-6, 8 and 9 are complete with evidence in `docs/evidence.md`. **Task 7 was not performed**: the `1.1` release images were not published on Docker Hub (only `1.0` exists for the frontend and backend), so tags `v1.1.0` and `v1.2.0` do not exist; staging remains at `v1.0.0`. Rebuild from an empty cluster (Task 9) took about 3 min 45 s to a working dev frontend.

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

# (Only if image pulls fail - section 13: load images from the host instead. 'kind load docker-image'
#  from kind v0.20.0 cannot detect the v1.36 node snapshotter, so import with ctr on each node:)
#  for img in quay.io/argoproj/argocd:v3.5.6 public.ecr.aws/docker/library/redis:8.2.3-alpine ghcr.io/dexidp/dex:v2.45.1 \
#             docker.io/bitnami/sealed-secrets-controller:0.40.0 rynorbu11/dso202-{db,backend,frontend}:1.0 busybox:1.37; do
#    docker pull $img; docker save --platform linux/amd64 $img -o /tmp/img.tar
#    for n in dso202-gitops-control-plane dso202-gitops-worker; do
#      docker exec -i $n ctr -n k8s.io images import --platform linux/amd64 --snapshotter overlayfs - < /tmp/img.tar; done
#  done

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
_Task 7 could not be run: the `1.1` release images were never published (see `docs/evidence.md`, Task 7). This answer is based on the documented behaviour of Argo CD v3.5._

**Why `argocd app rollback` is refused.** Rollback re-applies an earlier entry of `argocd app history` directly to the cluster, which makes the live state differ from what `main` says. With automated sync and self-heal enabled, the controller would immediately sync `main` again and undo the rollback, so Argo CD refuses the command on any Application with an `automated` sync policy (the documentation states that rollback is not possible when automated sync is enabled); the only way to use it would be to disable automation first, which leaves the cluster deliberately out of step with Git.

**The GitOps equivalent** is to change Git: `git revert <bad-commit>` creates a new commit whose content equals the state before the bad change; once it is merged to `main`, Argo CD pulls it and syncs dev back to the previous image like any other release. Task 8, Drill 4 used exactly this to recover from a commit the project refused (`d6ce000` reverted by `f374da6`). For staging the gate is the tag: it simply keeps pointing at the last good tag, so a bad commit on `main` never reaches it.

**Why revert rather than deleting the commit.** `main` is shared and already pulled by Argo CD and by every clone; rewriting it (`reset --hard` + force-push) breaks everyone's copy and can silently drop other people's later commits. A revert keeps the history complete and append-only (principle 2, versioned and immutable): the bad commit, the moment it was undone and who did it remain visible for the post-incident review, `argocd app history` stays consistent with Git, and the change itself can be reverted again when the fix is ready (fix-forward).

### Q6 (Task 9)
**(a) One repository for chart and environment configuration.**
Advantages:
1. *Atomic, simple changes.* A chart change and the values it needs (for example a new backend variable for C2) land in one commit and one pull request, so `main` is never in a state where the chart and its values disagree, and a single `git revert` undoes both.
2. *One place for everything, easy to rebuild.* Task 9 needed one `git clone`, one URL in every `sourceRepos`, and one history to audit; for a single small team and one application this is much less overhead than coordinating two repositories, their access rights and their versions.

Disadvantages:
1. *Unrelated changes trigger and mix with each other.* Every commit to `main` (README, evidence, chart, values, Argo CD objects) is a new revision for every Application that follows `main`, and the tag that pins staging also pins the chart *and* all configuration together; it is impossible to promote a config change without also taking whatever chart changes were merged meanwhile. The best-practice split lets the chart be versioned and released independently while config is promoted per environment.
2. *Access control is all-or-nothing.* Anyone who can change the chart can also change `environments/staging/values.yaml`, the Applications under `argocd/` and the platform layer; in a separate config repository, who may change what is deployed where can be restricted (and reviewed) separately from who may change the application packaging.

**(b) What is not under GitOps control after the rebuild, and how teams usually handle it.**
- *The bootstrap layer (`bootstrap/argocd`: Argo CD itself and its `argocd-cm` / `argocd-rbac-cm`).* It is in Git but applied by hand, so a change (Task 6, step 4) needs a manual `kubectl apply`; teams usually let Argo CD manage its own installation through an Application ("Argo CD manages Argo CD") after the first install, or install it with Terraform/a cluster-provisioning pipeline.
- *The root Application and the `platform` AppProject (`bootstrap/root`).* Applied once by hand, so deleting or editing them is not self-healed; teams keep them in Git like here and create them from the same provisioning automation (Terraform, Cluster API, or an ApplicationSet in a management cluster), with tight RBAC on who may touch the `argocd` namespace.
- *The sealing key.* It exists only in the cluster and in the manual backup in `../dso202-keys/`; teams keep it in a secret manager or KMS (or use an external-secrets operator backed by Vault/AWS Secrets Manager instead of Sealed Secrets) and back it up automatically after every key renewal.
- *The database contents.* Application data is state, not configuration, so Git cannot hold it and it was lost in the rebuild; teams protect it with scheduled backups and tested restores (for example `pg_dump` CronJobs, Velero volume snapshots, or a managed database service with point-in-time recovery).
- *(Also outside: the kind cluster itself, the reviewer's password, and the images loaded from the host cache.)* The cluster is created by `cluster/kind-cluster.yaml` but by hand; production teams create clusters with infrastructure-as-code, and keep account passwords in SSO instead of local accounts.
