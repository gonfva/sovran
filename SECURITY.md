# Security review of this proof

This is a review of the code in this repository, done before publishing it. It is not a penetration test of a running account. The stacks this code has been applied to are destroyed between demos, so nothing here is a claim about an environment you cannot see.

The product sentence is that the model answers only the client. The code holds some of that, and misses some of it. The misses are below.

## Credentials

This tree does not contain AWS keys, Hugging Face tokens, Terraform state, or filled-in account ids.

- `infra/config.hcl`, `terraform.tfvars`, and `*.tfstate` are gitignored. The committed examples use placeholder account ids.
- Packer reads `HF_TOKEN` from the environment. The token is not a committed variable.
- Private AMI ids appear in the Packer and operator notes as bake history. An AMI id does not let someone else launch that image. The account id those images belong to is not in this tree.
- Applying this yourself will put real account ids into local state. Do not commit that state, and do not open a pull request from a machine where `git add -A` can see it.

If you fork this and publish your fork, check the same list before the first push. A fresh repository was used here so earlier private history was not part of the publication.

## What the code actually enforces

- Agent, model, and endpoint subnets are created without an internet gateway and without a NAT route (`infra/modules/reference-core/network.tf`).
- The model load balancer is internal. It is not registered on the client endpoint service.
- With `s3_endpoint_policy` left on, the S3 gateway allows only buckets named `sovran-<account-id>-*`. In the S3-registry mode, the extra allowance for the AWS-owned ECR layer bucket is omitted.
- Each client gets a separate KMS key, code bucket, data bucket, task role, and endpoint service. `allowed_principals` is that client's account.
- Client buckets deny non-TLS transport. The image-registry bucket allows anonymous `GetObject` only from this VPC's S3 gateway endpoint, and Block Public Access stays on.
- The agent image does not contain the AWS SDK or CLI. Sync containers do the S3 calls.
- The agent writes transcripts under the session workspace and logs lengths, token counts, tool names, and status. It does not log the prompt or the reply.
- The client admin instance has no inbound rules, no SSH key, and requires IMDSv2. It does have a public address and unrestricted egress. That instance is the operator's side of the demo, not the agent tier.
- The filesystem jail resolves paths and refuses a symlink that leaves `/workspace`. Reads and writes are limited to named prefixes.

## What is missing

These are the gaps that matter if you were about to tell someone the guest cannot leak.

1. **The agent container can use the sync role.** ECS gives one task role to every container in the task. The credentials are available inside the agent container at the task-metadata endpoint. Omitting the SDK raises the effort. It is not a boundary. A prompt-injected agent that can run code can call S3 as that role. Host mediation, where the guest never sees those credentials, is out of scope of this proof.

2. **That role is the whole client, not one session.** It can list and read the client's documents, sessions, and outputs, and write sessions and outputs. It can also `kms:CreateGrant` on the client key with no `kms:GrantIsForAWSResource` condition. There is no KMS interface endpoint on the agent tier, so a grant call has no route today. The permission is latent: the day someone adds that endpoint, the grant becomes usable. Reading and writing the client's own buckets does not need that endpoint. S3 is reachable, and the gateway policy allows those buckets.

3. **There is still no path from the agent tier to the public internet.** That is the property that holds. A stolen prompt can be written into the client's own bucket. It cannot be posted to an arbitrary host, and it cannot be written to an attacker-owned bucket whose name falls outside the prefix, while the endpoint policy stays on. The exfiltration that no-NAT was built to stop is still stopped. The exfiltration that stays open is "anyone who can later read that client's bucket."

4. **The S3 policy matches a name prefix, not a list of buckets.** A bucket created later in the same account, with the same prefix, is inside the allowance.

5. **Every principal that can reach the gateway can read the image layers anonymously.** The registry bucket is not client data. It is still a wider read than "the execution role pulls the image."

6. **Metadata-only logs are a convention.** `images/agent/app.py` logs the fields above, and the HTTP access log includes the request path. Nothing in CI fails if a later change prints a body, puts the prompt in a query string, or lets an exception formatter include one. The model stub echoes the prompt in its HTTP response on purpose. That response must not grow a log line.

7. **The endpoint service trusts the whole client account.** `allowed_principals` is the account root, and `envs/reference/main.tf` sets `acceptance_required = false`. Any principal in that account can connect without an extra accept step. There is no per-session or per-role scope.

8. **The jail is Python, not a mount namespace.** It is the right check for the tools the agent exposes. A process that is not going through those functions is on the shared task volume with the sync containers.

9. **State is local and unlocked.** That is acceptable for one operator and a bad default the moment a second person applies. The cross-account service name is copied by hand from one env to another. A mis-paste points a client at the wrong service.

## What not to claim

- Do not say the guest has zero cloud credentials.
- Do not say a contract, a certificate, or a log review is what makes this private. The claim that is true is the missing route, plus the per-client key and bucket, plus logs that currently do not contain the prompt.
- Do not say the model plane is highly available. It is one GPU, capped at one, with a cold start measured in minutes.
- Do not treat the client admin instance's public address as a contradiction of the agent tier. It is a different network, and it is still a machine with open egress sitting in an account you are about to demo from.
