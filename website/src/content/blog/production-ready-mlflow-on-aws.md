---
title: 'Designing a Production-Ready MLflow Platform on AWS'
description: 'How I modernized MLflow on AWS, completed the production cutover, and validated a secure model-delivery pattern using Amazon S3 Files.'
pubDate: '2026-09-27T20:58:00-04:00'
---

Running MLflow is easy.

Running MLflow as a platform that other teams depend on is a different problem.

The difference is mostly everything surrounding the MLflow process: persistence, authentication, secrets, networking, DNS, TLS, deployment behavior, environment isolation, recovery, and how you move users from an old endpoint to a new one without turning the migration into an incident.

This article describes a platform modernization I worked on, from designing the AWS infrastructure to completing the production cutover. It also covers the next layer of the platform: delivering approved model versions to compute instances through Amazon S3 Files.

*Updated November 26, 2026: production cutover completed; approved-model mounting isolation validated in a sandbox.*

```text
Users / applications
        ↓
Private DNS
        ↓
Internal ALB + TLS
        ↓
ECS Fargate service
        ↓
 ┌───────────────┬─────────────────┐
 │               │                 │
Aurora         S3 artifacts     Secrets
PostgreSQL                      Manager
```

The important word is **platform**.

## Treat environments as real boundaries

A common anti-pattern is to build one MLflow server and let development, test, and production users share it indefinitely.

That may be convenient initially, but it creates coupling:

- experiments from different environments share one control plane,
- maintenance becomes a cross-environment event,
- authentication changes affect everyone at once,
- rollback becomes harder,
- testing infrastructure changes becomes risky.

A better path is to make each environment independently deployable:

```text
DEV       → its own service + persistence + DNS
SANDBOX   → its own service + persistence + DNS
PROD      → its own service + persistence + DNS
```

The exact number of environments depends on the organization, but the architectural property matters more than the labels: **a change in one environment should not require taking another environment along for the ride**.

## Use Fargate when the application does not need a server

MLflow itself is not a reason to manage EC2 instances.

For this pattern, ECS Fargate provides a useful middle ground:

- container scheduling without node management,
- integration with ALB target groups,
- task-level CPU and memory,
- deployment health checks,
- CloudWatch logging,
- task IAM roles,
- deployment circuit breakers.

A production-shaped service should have an explicit deployment policy rather than accepting defaults without thought.

For example:

```text
Desired tasks:             1 or more
Minimum healthy percent:   100
Maximum percent:           200
Deployment circuit breaker: enabled
Rollback:                  enabled
```

For a small internal platform, one task may be enough initially. The design should still make scaling to multiple tasks possible without changing the persistence model.

## Keep metadata outside the container

The tracking server is replaceable. Its metadata is not.

MLflow's backend store should therefore live in a managed database rather than inside the task filesystem.

Aurora PostgreSQL is a natural fit when the surrounding platform already standardizes on AWS-managed PostgreSQL.

The separation is important:

```text
ECS task
  = compute

Aurora PostgreSQL
  = experiments, runs, users, metadata

S3
  = artifacts
```

Now an ECS deployment can replace a task without replacing the experiment history.

That sounds obvious, but production reliability is often a collection of obvious decisions that were actually implemented.

## Artifact storage belongs in S3

Model artifacts, files, and experiment outputs should live in durable object storage.

S3 provides a better lifecycle for those objects than container-local storage:

- independent durability,
- IAM controls,
- encryption,
- versioning where appropriate,
- lifecycle policies,
- backup and replication options,
- no dependency on task replacement.

The application receives the artifact destination through configuration rather than embedding environment-specific paths in the image.

That keeps the container image portable between environments.

## Secrets are configuration, but they are not environment variables in Git

The application needs credentials and security material such as:

```text
database username
database password
administrative password
server secret key
```

Those should not live in source control.

The ECS task definition can reference AWS Secrets Manager and inject them at runtime.

The distinction I like to keep is:

```text
Non-secret application setting → environment variable
Secret material                → Secrets Manager reference
```

That makes the task definition readable without turning it into a credential store.

## Put an internal ALB in front of the service

For an internal ML platform, the load balancer does not need to be internet-facing.

An internal Application Load Balancer provides:

- stable service entry point,
- HTTPS termination,
- target health checking,
- separation between service tasks and clients,
- future horizontal scaling.

The public internet never needs a path to the MLflow task.

Private networking should be the default unless the business requirement explicitly says otherwise.

## DNS and TLS are part of the platform

A production system should not require users to remember an ALB hostname.

Use a stable DNS name such as:

```text
mlflow.<environment>.<internal-domain>
```

and terminate TLS with an ACM certificate.

This is more than cosmetic.

A stable DNS name gives the service an identity that survives:

- task replacement,
- target group changes,
- load balancer maintenance,
- future architecture changes.

Application configuration should also explicitly allow the expected hostnames rather than disabling host validation broadly.

## Authentication should have a migration path

Authentication is one of the areas where a proof-of-concept and an enterprise platform diverge quickly.

A temporary admin/basic-auth path can be useful during platform validation, but the architecture should anticipate SSO/RBAC.

A sensible rollout sequence is:

```text
Infrastructure
    ↓
Service health
    ↓
Basic authenticated validation
    ↓
Application/API testing
    ↓
SSO/RBAC integration
    ↓
Controlled user cutover
```

Trying to solve every identity requirement before proving that the service, database, artifact store, network path, and deployment model work can make troubleshooting unnecessarily difficult.

The trick is to use temporary authentication as a validation stage, not as the permanent target state.

## From authentication to model-level authorization

The modernization introduced Okta SSO for interactive users, alongside dedicated service identities for automated ingestion and API access. Existing platform access groups were associated with the MLflow application, removing the need for a separate manual SSO onboarding process for those users.

Authentication alone does not grant access to every model. Workspaces provide logical boundaries for model catalogs, while role-based permissions determine which users and services can read or manage registered models. In development, I tested this with a restricted service identity: it could retrieve an authorized model while attempts to access two other models were denied.

That separation is especially important when models are consumed by compute instances. A person signing in to the registry, an ingestion service registering artifacts, and an EC2 instance loading weights should not all inherit the same privileges.

## Blue/green thinking matters even when there is only one server

One of the safest ways to modernize an existing shared MLflow endpoint is not to mutate it in place.

Build the replacement beside it.

```text
Old MLflow endpoint  ← users still here

New MLflow endpoint
    ↓
validate infrastructure
validate auth
validate API
validate UI
validate artifact access
validate integrations

then:

DNS / application configuration
              ↓
          new endpoint
```

That gives you a straightforward endpoint rollback option, provided that database and artifact changes after cutover are also accounted for:

```text
cutover problem?
      ↓
point clients back to the known endpoint
```

You do not need a sophisticated service mesh to use blue/green principles. Sometimes it is simply two independently reachable stacks and a controlled switch.

## What I validate before cutover

A steady-state ECS service is necessary, but not sufficient.

My validation checklist includes:

- ECS desired task count equals running task count.
- Deployment is complete and stable.
- ALB target is healthy.
- HTTPS works through the intended DNS name.
- Database connectivity succeeds from the task.
- Experiment search API requires authentication.
- Authenticated experiment creation succeeds.
- Created experiments persist across task replacement.
- Artifact writes and reads succeed.
- Secrets are not present in source control or plain task configuration.
- Logs are available for failed requests.
- Rollback path is documented before cutover.

For example, creating a disposable validation experiment is much more meaningful than checking only `/health`.

It proves that the request reached the application, authentication worked, the server could write metadata, and the database path was functional.

## Completing the production cutover

The production DNS cutover has now been completed. Instead of requiring application teams to change their integrations, the replacement service took over the existing production hostname.

The rollout followed a staged approach:

- Validate the independent development and sandbox deployments.
- Establish SSO, service identities and workspace-level access boundaries.
- Test model registry access and authorized versus unauthorized model retrieval.
- Deploy the replacement production infrastructure alongside the legacy service.
- Switch production DNS to the new endpoint while retaining the existing URL.

Users who had temporarily overridden DNS during pre-cutover testing were asked to remove those overrides so they could resolve the production endpoint normally.

The production migration milestone is complete. Model distribution through mounted storage is a separate enhancement, with its own validation and rollout gates.

## Beyond the model registry: delivering approved models to compute

A model registry answers questions about model identity, version, provenance and access. But the workload still needs to obtain the model's actual files.

For an inference workload using large model weights, tokenizers and configuration files, downloading the same model separately to every EC2 instance can increase startup time, local disk consumption and operational effort. Giving those instances broad S3 permissions to solve that problem creates a different issue: a workload may be able to retrieve models that were never approved for it.

The design goal is therefore not just to make files accessible. It is to expose **only the approved, immutable model versions** to the intended workload.

Amazon S3 Files, which presents S3 objects through a shared file system, provides a useful mechanism for doing this. Unlike a generic mount of the entire artifact bucket, a scoped mount can expose a particular model version as a normal local directory.

### Separate registry storage from the approved model library

I designed a model-delivery layer with a controlled publication boundary between raw artifacts and the versions available for consumption.

```text
MLflow tracking server + model registry
                |
         Registration / validation
                |
         Approved model catalog
                |
         Versioned S3 model library
                |
         Amazon S3 Files
                |
        Model-version access points
                |
        Read-only EC2 model mounts
```

The model catalog maps the workspace, registered model name and exact version to the corresponding artifact location and file inventory. It also records readiness and the access-point reference. A publication process should verify that the complete model bundle is present before making it mountable.

A simplified, illustrative library layout might look like this:

```text
model-library/
  models/
    model-a/
      v1/
        manifest.json
        config.json
        model.safetensors
      v2/
        manifest.json
        config.json
        model.safetensors
    model-b/
      v1/
        manifest.json
        model.safetensors
```

The real object layout can differ from this example. The important property is that each version resolves to a stable, non-overlapping prefix with a verified manifest. The publisher must enforce immutability; naming a prefix `v1` does not make its contents immutable by itself.

This approach keeps model publication separate from model consumption. A new experiment, a new registry version, or a mutable alias changing targets must not silently replace the bytes that an approved workload sees.

### Mount the version, not the entire model library

An S3 Files access point can present a specific directory as the root of a mount. A version-specific access point, coupled with workload authorization, lets the platform expose paths like these:

```text
Instance A
  /models/model-a/v1    allowed, read-only
  /models/model-b/v1    not authorized

Instance B
  /models/model-b/v1    allowed, read-only
  /models/model-a/v1    not authorized
```

The proposed provisioning flow is:

1. A project requests access to a registered model and an exact version.
2. The platform checks the approval and resolves the validated artifact manifest.
3. A privileged provisioning service associates the approved access point and exact S3 object prefix with the workload's IAM role.
4. The instance mounts the approved version at a deterministic local path.
5. Approval changes trigger reconciliation of permissions and mount configuration.

The model registry is the source of model identity; the approval workflow determines which workload should receive access; AWS enforces the resulting storage permissions.

### Enforce authorization at every storage path

An access point is a namespace boundary, not a complete identity authorization policy. I use a layered design:

- **Network:** permit NFS connectivity on TCP 2049 only from intended compute networks to the mount targets.
- **File system policy:** restrict each workload role to its approved access-point ARNs, with explicit denies for other access points and direct root mounts.
- **Workload IAM:** allow read access through `s3files:ClientMount`; deny write and root privileges for the consumer role.
- **S3 permissions:** scope direct `s3:GetObject` and `s3:GetObjectVersion` to approved version prefixes; do not grant unrestricted bucket listing or reads. Apply bucket-policy and KMS controls where appropriate.
- **Local mount:** mount read-only and configure operating-system access for the intended workload.

The fourth layer is particularly important. S3 Files can serve reads directly from S3, so file-system permissions alone cannot prevent a workload with overly broad object-storage permissions from bypassing the mount. The direct-read permissions must describe the same approved version boundary as the file-system policy.

Similarly, an EC2 role is a workload identity, not an individual MLflow user's identity. On shared compute, per-user isolation requires additional operating-system or workload isolation; a mount does not inherit a person's SSO permissions.

See AWS's documentation on [S3 Files client access policies](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-files-access-point-policy-examples.html) and [IAM authorization for S3 Files](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-files-security-iam.html).

### Prepare compute instances for model mounting

For supported Linux EC2 instances, the S3 Files mount helper is provided by `amazon-efs-utils` (version 3.0.0 or later). The platform's machine image or bootstrap process should install the helper and its dependencies, attach the approved instance profile, and verify DNS, mount-target connectivity and access to S3.

An illustrative mount command is:

```bash
sudo mkdir -p /models/model-a/v1

sudo mount -t s3files \
  -o ro,accesspoint=fsap-EXAMPLE \
  fs-EXAMPLE:/ /models/model-a/v1

findmnt -T /models/model-a/v1
```

The filesystem and access-point IDs above are placeholders. S3 Files uses authenticated, encrypted mount connections; a local read-only flag is an additional safeguard, not a substitute for IAM enforcement.

Mount configuration can be generated from approved entitlements and reapplied at instance startup. Revocation needs special attention: remove permissions, unmount the affected path, and test existing connections as well as new ones. Previously downloaded or cached copies cannot be assumed to disappear when approval is revoked.

See the [EC2 mounting instructions](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-files-mounting.html) for current prerequisites and supported operating systems.

### Validate the negative cases, not just the successful mount

In a sandbox proof of concept, I tested the isolation boundary using two model prefixes and a restricted compute identity. The tests covered:

| Test | Observed result |
| --- | --- |
| Mount and read the authorized model | Allowed |
| Mount the other model's access point | Denied |
| Write to the read-only model mount | Denied |
| Mount the file-system root | Denied |
| List the underlying bucket directly | Denied |
| Read an unauthorized model object directly from S3 | Denied |

A successful mount alone would not have demonstrated that the design was secure. Testing the alternate paths was the most valuable part of the exercise.

The next rollout gates are end-to-end approval-driven provisioning, policy reconciliation and revocation, concurrent multi-instance access, and production-scale performance and cost validation. Access-point and policy quotas also need to be accounted for as the number of versions and workloads grows.

The intended benefits are fewer redundant local model copies, a simpler model-loading experience and a storage authorization boundary tied to exact model versions. Startup latency, storage savings and operating cost should be benchmarked before claiming quantified improvements.

## The operational goal

The best outcome is not "MLflow is running."

It is:

> MLflow becomes a boring internal platform that can be deployed, upgraded, recovered, authenticated, and handed to another engineer without requiring tribal knowledge.

The same principle applies to model delivery: the workload should see the model versions it is authorized to consume, through a repeatable and auditable provisioning process, rather than receiving access to an entire artifact store.

That is the difference between standing up a tool and engineering a platform.
