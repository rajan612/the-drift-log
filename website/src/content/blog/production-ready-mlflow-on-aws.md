---
title: 'Designing a Production-Ready MLflow Platform on AWS'
description: 'A practical architecture for isolating MLflow environments, protecting persistence, managing secrets, and planning a controlled production rollout.'
pubDate: '2026-09-27T20:58:00-04:00'
---

Running MLflow is easy.

Running MLflow as a platform that other teams depend on is a different problem.

The difference is mostly everything surrounding the MLflow process: persistence, authentication, secrets, networking, DNS, TLS, deployment behavior, environment isolation, recovery, and how you move users from an old endpoint to a new one without turning the migration into an incident.

This is the architecture pattern I use when thinking about a production-ready MLflow deployment on AWS.

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

That gives you a clean rollback:

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

## Production-ready does not mean production-complete

There is an important distinction between **designing for production** and claiming a production migration is complete.

A production-ready platform can have:

- production-grade isolation,
- private networking,
- managed persistence,
- TLS,
- secret management,
- deployment controls,
- rollback planning,

while the rollout itself is still moving through development, sandbox, and final production validation.

That distinction keeps architecture claims accurate and makes project status easier for everyone to understand.

## The operational goal

The best outcome is not "MLflow is running."

It is:

> MLflow becomes a boring internal platform that can be deployed, upgraded, recovered, authenticated, and handed to another engineer without requiring tribal knowledge.

That is the difference between standing up a tool and engineering a platform.
