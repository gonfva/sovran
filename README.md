# Sovran

AI that answers only to you.

This repository is a reference architecture: an agent and a model on AWS, with no general route to the internet, and with two clients that cannot see each other's data. It is the proof behind [sovran.uk](https://sovran.uk).

It is not a hosted product, and it is not a multi-tenant SaaS. You can read it, run it in accounts you control, and tear it down.

## What you can prove with it

- A client reaches only their own agent, over PrivateLink.
- The agent and model networks have no NAT and no internet gateway route.
- Inference stays on a private model plane. The model load balancer is internal.
- Each client has their own key and their own buckets. Session transcripts are client data. Platform logs are written to carry metadata only.
- Container images can be served from a bucket in the same account, so the agent tier does not need a registry on the internet.

## What it does not prove

One cloud permission is still shared by the containers that move files and the container that runs the agent. A guest with no cloud credentials at all is not what this repository is. [SECURITY.md](./SECURITY.md) is the list of gaps, written so they are not papered over. [WEAKNESSES.md](./WEAKNESSES.md) is the longer critique.

## Run it

You need three AWS accounts and named CLI profiles. The operator runbook is [infra/README.md](./infra/README.md): apply order, the isolation demo, and the destroy order. Idle cost is real. Destroy the stacks after a demo.

Copy `infra/config.example.hcl` to `infra/config.hcl` and fill in account ids locally. Do not commit that file, `terraform.tfvars`, or Terraform state. A Hugging Face token, if you bake a model image, stays in the environment (`HF_TOKEN`). It is never a Terraform variable you commit.

The plan of record for the proof is [PLAN.md](./PLAN.md).

## License

Apache License 2.0. Copyright 2026 Xowit Labs Ltd. See [LICENSE](./LICENSE) and [NOTICE](./NOTICE).
