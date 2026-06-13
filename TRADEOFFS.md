# Architectural Trade-offs & Decisions

This document records the key architectural decisions, their rationale, the alternatives considered, and the risks mitigated.

---

## 1. RAG-Enhanced AI Validation (Bedrock + OpenSearch Serverless)

### Decision
Use Retrieval-Augmented Generation (RAG) to validate code/config changes against a live HIPAA/FDA compliance rule database before deployment, rather than static linting or manual review.

### Why
Static linters (Checkov, tfsec) catch infrastructure misconfigurations but cannot reason about business logic or policy intent. A RAG approach grounds Claude's responses in the organization's specific compliance rules, reducing hallucination and producing traceable audit decisions.

### Trade-offs

| Pro | Con |
|-----|-----|
| Catches semantic compliance violations, not just syntax | Adds latency (~2–5s per validation call) to the pipeline |
| Audit log tied to specific rule IDs for FDA traceability | OpenSearch Serverless has a minimum cost even at zero traffic |
| Rules can be updated without changing pipeline code | Bedrock API availability is a new external dependency |

### Risk Mitigation
- Pipeline fails **closed**: if the Lambda times out or Bedrock is unavailable, the deployment is blocked, not allowed.
- All decisions (compliant or not) are logged to DynamoDB with rule IDs for auditor review.

---

## 2. SLSA v1.0 Provenance + Cosign Image Signing

### Decision
Generate SLSA Level 3 provenance attestations in CI and sign all container images with Cosign (keyless via Sigstore, or KMS-backed for air-gapped environments). Kyverno enforces both at the cluster gate.

### Why
HIPAA §164.312(c) requires integrity controls on ePHI-processing software. SLSA + Cosign creates a tamper-evident chain from source commit to running container, proving no unauthorized changes occurred between build and deploy.

### Trade-offs

| Pro | Con |
|-----|-----|
| Cryptographic proof that images weren't tampered with post-build | Adds ~1–2 min to CI pipeline for attestation generation |
| Kyverno blocks unsigned images cluster-wide (zero exceptions) | Teams must manage Cosign keys or maintain Sigstore OIDC trust |
| Satisfies FDA 21 CFR Part 11 software integrity requirements | Kyverno in Enforce mode will block ALL deployments if misconfigured |

### Risk Mitigation
- Kyverno policies are applied to application namespaces only; `kube-system` is excluded to prevent cluster lockout.
- A break-glass procedure (documented separately) allows temporary policy bypass with dual approval.

---

## 3. S3 WORM Bucket (Object Lock — COMPLIANCE Mode)

### Decision
Store all audit reports, scan results, and SLSA provenance in an S3 bucket with Object Lock in **COMPLIANCE mode** with a 2,190-day (6-year) retention period.

### Why
HIPAA requires medical records and audit logs to be retained for 6 years. COMPLIANCE mode means even the AWS root account cannot delete objects before the retention period expires, satisfying the "immutability" requirement for FDA audit trails.

### Trade-offs

| Pro | Con |
|-----|-----|
| Legally defensible immutability for HIPAA/FDA auditors | Objects cannot be deleted under any circumstance until retention expires |
| No code change can accidentally or maliciously purge audit history | S3 storage costs accumulate over 6 years (use S3 Intelligent-Tiering) |
| Passes AWS Well-Architected audit for regulated workloads | A misconfigured retention period requires AWS Support to correct |

### Risk Mitigation
- Bucket is deployed with `prevent_destroy = true` in Terraform to block accidental `terraform destroy`.
- S3 Intelligent-Tiering lifecycle rule moves objects to cheaper storage tiers after 90 days.

---

## 4. Ephemeral PR Environments

### Decision
Spin up an isolated Kubernetes namespace per pull request, deploy the full application stack, run integration tests, and tear it down when the PR is closed.

### Why
Persistent staging environments drift from production over time and become shared-state bottlenecks. Ephemeral environments give each PR a clean, production-like test surface with zero cross-PR contamination.

### Trade-offs

| Pro | Con |
|-----|-----|
| Catches integration bugs before merge, not after | Increases EKS node utilization during peak PR activity |
| Zero shared state between PRs | Cold-start time (~2–3 min) increases PR feedback loop |
| Namespace-scoped NetworkPolicy provides security isolation | Requires careful resource quotas to prevent node exhaustion |

### Risk Mitigation
- Each ephemeral namespace has a `ResourceQuota` capping CPU and memory.
- A 4-hour TTL job automatically cleans up namespaces from abandoned PRs.
- Zero-trust `default-deny` NetworkPolicy is applied to every ephemeral namespace immediately on creation.

---

## 5. GitOps with ArgoCD (App-of-Apps Pattern)

### Decision
Use ArgoCD with the App-of-Apps pattern for all Kubernetes deployments instead of `kubectl apply` or `helm upgrade` in CI.

### Why
Direct `kubectl` commands in CI pipelines create out-of-band cluster state that is hard to audit and impossible to roll back declaratively. ArgoCD makes the Git repository the single source of truth and provides a full audit trail of who changed what and when.

### Trade-offs

| Pro | Con |
|-----|-----|
| Full GitOps audit trail (who approved the merge = who deployed) | ArgoCD itself is another component to operate and secure |
| Self-healing: ArgoCD corrects drift automatically | App-of-Apps bootstrapping requires a manual first-time ArgoCD install |
| Rollback = revert the Git commit | ArgoCD admin credentials must be protected (stored in Ansible Vault) |

### Risk Mitigation
- ArgoCD admin password is encrypted with `ansible-vault` and never stored in plaintext.
- ArgoCD RBAC is configured so developers can sync but not modify application definitions.

---

## 6. Ansible for EKS Add-on Deployment (vs. Pure Terraform)

### Decision
Use Ansible (not Terraform) to install Kubernetes add-ons (Kyverno, ArgoCD, Prometheus, Secrets Store CSI Driver).

### Why
Terraform's Kubernetes/Helm providers are stateful and can fail on cluster upgrades or re-creates because they retain resource state in `tfstate`. Ansible's `kubernetes.core.helm` module is idempotent and stateless — it queries the cluster directly, making it safer for mutable cluster configuration that changes frequently.

### Trade-offs

| Pro | Con |
|-----|-----|
| No risk of Terraform state corruption for in-cluster resources | Two tools to learn (Terraform for infra, Ansible for config) |
| Idempotent: safe to re-run after EKS upgrades | Ansible requires a working `kubeconfig` and cluster access |
| Ansible Vault encrypts sensitive Helm values natively | Slightly more verbose than a single `terraform apply` |

### Risk Mitigation
- `ansible.cfg` pins `retry_files_enabled = False` to prevent stale `.retry` files from masking failures.
- CI runs `ansible --check` (dry-run) on PRs before merging changes to playbooks.
