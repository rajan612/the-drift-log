---
title: 'From Intent to Code'
description: 'Architecting a governed, agentic software delivery platform where AI proposes changes, deterministic checks verify them, and humans remain accountable.'
pubDate: '2026-11-26T06:25:00-05:00'
---

Writing code is becoming easier.

Knowing whether it is the right code is not.

A coding agent can turn a few sentences into a working implementation. But a working implementation is not necessarily a safe change, a maintainable design, or even a solution to the problem the user intended to solve.

The difficult part of software engineering is not just producing code. It is translating an ambiguous requirement into a change that can be explained, verified, reviewed, and operated.

That is the problem I find interesting: **how do we turn human intent into trustworthy engineering outcomes?**

This article explores a generalized reference architecture for governed, agentic software delivery. The examples are illustrative rather than descriptions of any proprietary system.

## CI/CD solved a different problem

Traditional CI/CD typically begins once a proposed code change exists. It automates building, testing, validating, and delivering software, but it does not inherently determine whether the original requirement was understood correctly.

```text
Code change → Build → Test → Release
```

It makes the delivery process repeatable. It can establish whether a commit compiles, whether tests pass, and whether an artifact satisfies release policies.

But it does not necessarily answer:

- What problem are we solving?
- Is this change necessary?
- Does the implementation satisfy the original requirement?
- What existing behavior could it break?
- Does the change introduce a new security or operational risk?

AI creates an opportunity to bring automation further upstream, before the first line of code is written.

```text
Intent → Plan → Implement → Verify & Remediate
                                  ↓
                       Human publication approval
                                  ↓
                         Reviewable pull request
                                  ↓
                          Existing CI/CD + review
```

This is not a replacement for CI/CD. It is an extension of the engineering process around it.

## Start with intent, not a prompt

Imagine a request to add a new export endpoint to an existing application.

"Build an export endpoint" is a prompt. It is not yet an engineering specification.

A useful engineering intent might include the expected output format, access restrictions, maximum data volume, compatibility with existing clients, failure behavior, and acceptance tests. It should also describe what must not change.

For example, the request may explicitly prohibit exporting restricted records, changing existing API contracts, or introducing a new public network dependency.

The distinction matters because an agent that receives only the first sentence can produce something plausible while making several unapproved design decisions.

The goal is to establish a contract between the person requesting the change and the system performing it. Missing requirements should be surfaced rather than silently invented.

## The agent is not the platform

One way to think about agentic engineering is to separate the reasoning layer from the execution and governance layers.

![Governed agentic software delivery architecture: requirements, independent plan review, implementation, validation, security remediation loop, human publication approval, pull request, code review and CI/CD, then authorized merge or release.](/images/from-intent-to-code-architecture.svg)

*Reference architecture: independent security verification and two distinct human approval gates.*

The reasoning layer proposes plans, interprets repository context, and generates changes.

The orchestration layer manages state, sequencing, timeouts, retries, and approval boundaries.

The execution layer provides access to tools, source code, and test environments; stronger runtime isolation is a separate security design goal.

The policy layer determines what actions are permitted, regardless of what the model proposes.

Keeping these responsibilities separate makes the system easier to reason about. It also means the language model can be replaced without having to redesign the entire delivery process.

A workflow should not depend on a particular model's ability to remember every instruction throughout a long conversation.

## Plan before changing anything

Before implementation begins, an agent should inspect the relevant project context and explain the proposed change.

A useful plan is not a long dump of generated source code. It describes the affected components, design choices, dependencies, expected behavior, risks, and verification strategy.

There is a practical reason to do this first: correcting a mistaken architectural assumption is cheaper before the system has produced a large diff.

A plan should make uncertainty visible. If the agent cannot determine how an existing authorization boundary works, for example, it should not assume that adding a new endpoint is harmless.

The level of scrutiny should follow the risk. Renaming an internal variable is different from changing an identity policy, a database schema, or a production network boundary.

## Separate the implementer from the reviewer

A model that produces a solution is not necessarily the best judge of that solution.

An independent review stage can examine the proposed plan or resulting change against the original intent, paying particular attention to missed requirements, security concerns, and compatibility.

Independence here is a design property, not a guarantee of correctness. Two agents can share the same blind spots, especially when they use similar models and context.

This is why model-based review should complement, rather than replace, deterministic checks and accountable human decisions.

The review should have a meaningful outcome: accept the proposed direction, request specific rework, or escalate unresolved questions. Rework should be bounded. An agent that repeatedly fails the same check should stop and explain the blocker instead of consuming resources indefinitely.

## Passing tests is not enough

A green pipeline can still accompany a wrong implementation.

Suppose the new export endpoint returns valid CSV data. The test passes. But the endpoint also returns records belonging to a different tenant.

The implementation meets one requirement and violates another.

Verification needs to cover both the behavior being introduced and the invariants that must remain true.

| Verification layer | Question it answers |
| --- | --- |
| Build and static analysis | Is the change structurally valid? |
| Unit and integration tests | Does the expected behavior work? |
| Negative and security tests | Are prohibited behaviors rejected? |
| Regression tests | Does existing behavior still work? |
| Policy checks | Does the change satisfy mandatory controls? |
| Human review | Is this the right change to make? |

The exact toolchain will vary by project. The principles do not.

A Python service, a TypeScript application, and an infrastructure repository may need different validation commands. A reusable engineering platform should discover or receive those commands through project configuration rather than assume a particular stack.

Existing checks should not be weakened merely to make an agent-generated change pass. Changes to tests or security policies deserve their own scrutiny.

### Shift security left with agentic remediation

Security scanning should not be limited to identifying vulnerabilities after a pull request has already been created.

An agentic delivery platform can introduce a security gate before publication. Generated changes are checked against deterministic security rules, and actionable findings are passed to a specialized remediation agent.

The remediation agent proposes targeted fixes in an isolated working copy. The platform then independently rescans the modified code, reruns relevant validation, and requests further review when necessary.

```text
Generated change
       |
Deterministic security scan <----------------+
       |                                     |
       +-- Findings --> Remediation agent    |
       |                       |             |
       |               Targeted fix          |
       |                       |             |
       |               Rerun validation -----+
       |
       +-- Pass --> Human publication approval
                        |
                 PR creation if approved

Unresolved findings or retry limit reached:
    block publication and escalate for human review
```

Importantly, the agent does not decide whether its own remediation succeeded. The verification layer makes that determination. A scanner passing means that the configured checks passed, not that the code is free of vulnerabilities. Disabling a check or weakening a policy is not an acceptable substitute for fixing a finding.

Consider an illustrative infrastructure change that permits unrestricted inbound access to an administrative service. A native configuration rule detects the overly permissive setting. A remediation agent proposes narrowing access to the intended network boundary. The platform reruns the security scan and infrastructure validation to establish whether the revised change meets the requirement. If the intended boundary is unknown, it should stop and ask rather than invent a trusted network.

This approach can reduce security findings that reach the pull-request stage while preserving independent security checks in the existing CI/CD pipeline. It is a feedback loop, not a replacement for defense in depth.

Native configuration and policy checks address a defined set of known insecure patterns. They are distinct from continuously updated CVE intelligence. A more mature implementation could combine those checks with current vulnerability advisories and dependency inventories, allowing agents to identify known vulnerable dependencies and propose upgrades before changes reach code review. Such upgrades would still require compatibility testing and independent verification.

## Give agents tools, not unlimited authority

A coding agent becomes more useful when it can inspect files, run tests, and interact with development tools.

It also becomes more capable of causing unintended damage.

An execution environment should therefore provide the minimum permissions necessary for the current task.

There is an important distinction between an isolated Git working copy and a hardened security sandbox. A separate checkout helps prevent ordinary edits from disrupting another working tree, but it does not by itself prevent an AI-powered CLI from accessing other local files, environment credentials, or network resources available to its process.

A stronger target architecture would enforce process or workload isolation, scoped and short-lived credentials, restricted filesystem access, constrained network egress, and explicit authorization for destructive operations. These controls need to be implemented and tested separately; they should not be assumed merely because the agent operates in its own working copy.

Repository content, issue descriptions, and tool outputs should be treated as potentially untrusted inputs. Instructions embedded in a file should not override system policy or grant additional permissions.

Most importantly, the agent should not be able to approve its own privileged actions.

Generating infrastructure code is not authorization to deploy it. Preparing a database migration is not authorization to execute it against production. Creating a proposed change is not authorization to publish it as a pull request. Approval to create the pull request is separate from approval to merge it.

These boundaries should be enforced by the platform and external systems, not merely expressed as instructions to a model.

## Make the change explain itself

The final output should be a reviewable pull request—not merely generated code—with a traceable connection to the original requirement, documented validation results, security findings, and clear human approval boundaries. A human should authorize publication after verification passes; the resulting pull request must still undergo independent code review and CI/CD checks before an authorized merge or release.

In the target architecture, the pull request should link back to its originating work item, identify the intended reviewers, and make the relevant evidence accessible, either directly or through linked records:

- The requirement it addresses.
- The implementation decisions and their rationale.
- The checks that ran and their actual outcomes.
- Security findings, remediation outcomes, and any unresolved blockers or approved exceptions.
- Known limitations and unresolved risks.
- Any relevant operational or rollback considerations.

For example, an infrastructure change may compile and pass policy validation without ever having been applied. The review record should distinguish those facts. "Validated" should not imply "deployed."

A reviewer should be able to understand the change without reading an entire agent conversation. Complete evidence publication is an architectural goal; a pull request alone does not establish that every validation or remediation report has been captured.

## Design for interruptions, not just the happy path

An engineering workflow is rarely a single uninterrupted run. Requirements change. Test environments fail. A reviewer requests revisions. An external dependency becomes unavailable.

A robust system should preserve enough state to determine where execution stopped and which evidence is still valid.

It should associate the request with its proposed change, avoid duplicate side effects on retries, and invalidate stale verification when the underlying code or requirements change.

Retries should have limits, and approval should be associated with a specific version of the proposed change. An approval for one revision is not automatically an approval for the next.

This is familiar distributed-systems thinking applied to agentic workflows: explicit state, idempotency, bounded failure, and traceable transitions.

## Measure engineering outcomes, not generated code

The number of lines generated by AI is not an especially useful success metric.

More meaningful measurements include:

- Time from a well-defined request to a reviewable change.
- First-pass acceptance and the amount of rework required.
- Defects that escape verification.
- Reviewer effort and security-policy violations.
- Execution cost and latency per accepted change.

These should be compared against a baseline and interpreted together. A system that generates pull requests twice as quickly but doubles review effort has not necessarily improved engineering productivity.

The point is to improve the entire delivery process, not to optimize one step in isolation.

## From intent to code

I do not think the most interesting future of AI in engineering is an agent that can write increasingly large amounts of code without supervision.

It is a system that understands the boundaries of a task, knows what evidence it needs, stops when it encounters uncertainty, and makes its work accountable to the people responsible for the software.

AI can propose the change.

Tests can establish specific facts about it.

Policies can constrain what it is allowed to do.

Humans remain accountable for the decision to ship it.

That is the difference between generating code and engineering a system that turns intent into code worth delivering.
