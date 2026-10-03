# Sovran — Weakest Points

A candid critique of the reference architecture as **planned** (`PLAN.md`) and as **implemented** (`infra/`), ranked by how much they undercut the product's core promise. The discussions already name the *conceptual* weak points well; this focuses on where the **PoC as built** falls short of its own thesis, plus the honest strategic risks.

The thesis is "isolation is the product." So the sharpest critique is: **where does the code not yet enforce what the marketing claims?**

---

## 1. Two core properties are gated on unbuilt/unproven work (severity: high)

The differentiator vs. "OpenClaw Pool + Bedrock" is *clampdown*: private inference and a credential-free guest. Both are honestly represented on the site — this is not a copy problem — but both are, today, *design goals with a documented gap*, and the demo currently proves *networking*, not the full privacy wedge.

- **The real model plane has never run end-to-end.** Phase 5 baked an AMI but every account had GPU quota 0, so no real completion has ever been served. The demonstrated inference path is the **echo stub**. "Private inference" is *architected and wired*, not yet *proven*.
  - **Mitigated by process (owner's decision):** the site launch is explicitly gated on a real Gemma completion running E2E — pending an AWS GPU-quota appeal — and if the model cannot run, the site is not worth shipping. So this is a *precondition the owner controls*, not a standing credibility gap. It stays on this list only because it is unproven *at time of writing*; it should close the moment quota is granted and the E2E test passes.

- **"Agent has no cloud credentials" is a roadmap goal, not a shipped control — and the site says so.** On Fargate, one task IAM role is shared by `sync-down`, `agent`, and `sync-up`; the credentials are reachable at `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` from any process in the task. A compromised agent (the exact prompt-injection threat the product exists to counter) can reach that endpoint and use the sync role's S3 + KMS rights directly. The agent image omitting the AWS SDK raises the bar but is a *soft mitigation, not a control*.
  - **Fairly disclosed:** the site states this plainly in three places — the FAQ ("one task IAM role is still shared across containers… roadmap work"), the "Honest limit · ECS residual risk" card, and the "what it deliberately is not" list ("Proof that residual ECS task-role risk is gone"). This is an accurately labeled limitation of the PoC, not a claim outrunning the implementation. Closing it for real needs host mediation (Firecracker or EC2 host-mount), which is explicitly out of scope here.

**Why it hurts (residual):** even after launch, the *technical* residual — shared task role — remains until host mediation lands. That's an accepted, disclosed PoC limit, not a misrepresentation. The item to actually track is the model E2E proof.

---

## 2. No-NAT is enforced by omission, not by a deny (severity: high) — **CLOSED 2026-08-14**

The isolation rests on "no NAT, no IGW route on agent/model subnets." That is correct and strong — but it was enforced only by the *absence* of a route. There was no defense in depth:

- ~~**No S3 gateway endpoint policy.**~~ `reference-core/endpoints.tf` attached the S3 gateway to all three route tables with **no policy**, so it permitted every bucket in the partition. Since the S3 API is the one egress the agent *can* reach, an injected agent (via the shared role, see #1) could read/write **arbitrary third-party S3 buckets that allow it**, or exfiltrate to an attacker-controlled bucket.

  **Fixed in two steps.** Phase 6 added `s3_endpoint_policy` (default on), narrowing the gateway to `sovran-<account>-*` **plus** the AWS-owned `prod-<region>-starport-layer-bucket` that ECR image pulls require — a bucket we can neither inspect nor reason about, sitting inside our only egress. Phase 8 removed the need for it: with `registry_mode = "s3"` the images come from our own bucket and that statement is gone. Verified live 2026-08-14 — the applied policy is a single `OwnBuckets` statement and nothing else.
- ~~**No bucket TLS-deny or VPCE-deny.**~~ Phase 6 added an `aws:SecureTransport = false` deny to every client bucket; Phase 8 added the same to the registry bucket, whose anonymous read grant is additionally conditioned on `aws:SourceVpce`. Verified live: an anonymous fetch of a manifest from the public internet returns **403**, while Block Public Access stays fully on and `get-bucket-policy-status` reports `IsPublic: false`.

**Residual.** Two things this does *not* claim. The gateway policy matches by name prefix (`sovran-<account>-*`), so anything an operator names to that pattern in this account is reachable — it is an account-scoped boundary, not a per-bucket allowlist. And the registry's VPCE condition governs the *anonymous* grant only: IAM principals in this account keep whatever S3 access their own policies give them, from anywhere, exactly as with every other bucket. Phase 8 also introduced its own cost, tracked under #1: any process in the VPC can now read every image layer anonymously.

---

## 3. Endpoint-service allowlist is coarser than the story (severity: medium)

`privatelink.tf` sets `allowed_principals = ["arn:aws:iam::<client>:root"]` and `acceptance_required = var.acceptance_required` (false in the lab). That means:

- **Any** principal in the client account — not a specific role — can connect to that client's agent. Fine for a PoC, but the hierarchical org/scope/principal vocabulary the discussions spent pages on is **entirely absent from the code**. There is no scope, no session-scoped credential minting, no per-principal authorization. The "soft tenancy" story (departments, Chinese walls, mint-time scoping) is vision-only.
- With `acceptance_required=false`, connection is automatic. Acceptable for a lab, but it is the kind of "weaker for convenience" default the project's own thesis argues against.

**Why it hurts:** the plan sells *hierarchical* isolation as a maturity axis; the PoC only demonstrates *account-level* isolation. That's the easy 80%. The hard part (scoped credentials at mint time — repeatedly called the "real isolation primitive") isn't started.

---

## 4. Operational fragility: local state, three real accounts (severity: medium)

- **Terraform state is local** (`terraform.tfstate` under each env, gitignored). For a design whose entire value is careful cross-account isolation, local unlocked state is a real risk: no locking, no history, easy to lose, easy to apply from a stale copy. A remote backend with locking is table stakes before anyone else touches this.
- **Cross-account wiring is manual.** Reference outputs an `endpoint_service_name` that must be hand-copied into each client env. Documented, but error-prone and un-CI-able — and a mis-paste points a client at the wrong service.
- **Idle cost is a demo-killer.** Interface endpoints ×5, per-client NLBs, internal ALB, Fargate, EC2, and (if enabled) a `g4dn.xlarge` accrue whether or not anyone is demoing. The README is honest about this, but "cold operator applies, demos, destroys from README alone" (Phase 6 exit) is unverified.

---

## 5. The transcript/observability boundary is asserted, not enforced (severity: medium)

The plan's strongest *conceptual* contribution is "session data is tenant data; platform logs are metadata-only." The agent code is claimed to log metadata only. But:

- Nothing **structurally prevents** a prompt body from reaching CloudWatch — it's a code convention in `app.py`/`loop.py`, not a guardrail. One stack trace that includes a prompt, or one `print(request)` during debugging, breaks it silently. There is no redaction layer, no test asserting "no prompt bytes in the log group."
- The "host-mediated infer proxy as tamper-evident system of record" idea (discussion 003) is not present; the guest writes its own transcript, so a misbehaving agent can omit or forge it.

**Why it hurts:** this is exactly the "soft exfiltration channel you already banned NAT for." A boundary that depends on every future developer remembering a convention is the failure mode the project claims to design against.

---

## 6. Strategic / framing risks (severity: medium — non-technical)

- **Capability gap is real and under-sold.** Gemma-4-E2B is a *small* model. For finance agent workloads (tool use, long context, reasoning), it will lose badly to frontier APIs. The site says "privacy is the trade" — honest — but a buyer who tries it and finds the agent can't complete the job won't care how private it is. There is no capability bake-off (discussion 001 §4.7 explicitly recommended one before building).
- **"Vision + working PoC" invites the wrong test.** The site foregrounds vision heavily and the PoC as "evidence." But the PoC's most impressive-sounding properties (private inference, credential-free guest) are the two least proven (#1). The gap between narrative confidence and demonstrated fact is the thing a sharp CISO will probe first.
- **OpenClaw Pool overlap.** The discussions correctly argue the wedge is "clampdown + local models," not Firecracker plumbing. But since Firecracker/host-mediation is roadmap and the local model never ran, the *currently demonstrable* delta vs. that AWS sample is thin: "same ECS-ish isolation, but with no NAT and a stub model." The unique value is entirely in the unbuilt parts.

---

## Summary ranking

| # | Weak point | Type | Status |
|---|------------|------|--------|
| 1 | Private inference unproven at time of writing (launch-gated); shared task role is a disclosed residual, not a shipped control | Core promise | Launch-gated / honestly disclosed |
| 2 | No-NAT enforced by omission; no S3 endpoint policy or bucket TLS/VPCE deny | Defense in depth | **Closed** (Phase 6 policy + TLS deny; Phase 8 removed the ECR-layer allowance) |
| 3 | Only account-level isolation; hierarchical scope/mint-time creds absent | Scope vs. plan | Vision-only |
| 4 | Local unlocked state, manual cross-account wiring, idle cost | Operations | Open |
| 5 | Metadata-only logging is convention, not guardrail | Observability | Open |
| 6 | Small-model capability gap; vision outruns proof | Strategy | Unaddressed |

**The single most important item:** the model E2E proof (#1, first bullet). The owner has already correctly gated launch on it — a real Gemma completion over the private path must run before the site ships, and if it can't, the site is moot. The site copy already presents both private inference and the credential story fairly (as goals with disclosed gaps), so no softening is needed.

**Update 2026-08-14.** #1's first bullet is discharged: a real Gemma 4 completion, including a parsed tool call, has now run on live GPUs in two regions (A10G/eu-west-1 2026-08-13, L4/eu-west-2 2026-08-14). #2 — previously called out here as the highest-value standing hardening, and the one place the "default-deny that survives pressure" thesis rested on the absence of a route — is **closed** by Phases 6 and 8, with the residuals stated in its section. The shared task role (#1, second bullet) remains the honest residual and is **made slightly worse** by Phase 8's anonymously-readable image layers. #3–#6 are unchanged.
