---
title: 'When Infrastructure Drift Becomes a Production Capacity Incident'
description: 'A real-world look at how an out-of-band Auto Scaling Group change created Kubernetes scheduling failures, and what Terraform and CloudFormation can do to make infrastructure drift visible and manageable.'
pubDate: '2026-09-30T23:12:00-04:00'
---

Infrastructure drift rarely announces itself.

There is usually no failed deployment.

No red dashboard.

No obvious infrastructure alarm.

Everything can look healthy right up until the workload asks the platform to do something it can no longer do.

That is what happened when an Auto Scaling Group that was supposed to support a maximum of **40 nodes** was manually changed to a maximum of **4**.

The code still said 40.

AWS was configured for 4.

The difference sat quietly until a data pipeline needed to scale horizontally.

Then Kubernetes started accumulating Pending pods.

The interesting part of the incident was not the Auto Scaling Group itself. It was the gap between **declared infrastructure** and **actual infrastructure**.

That gap is infrastructure drift.

## The change nobody intended to deploy

The intended capacity model looked roughly like this:

```text
Terraform

minimum capacity:  ...
desired capacity: ...
maximum capacity: 40
```

At some point, the live AWS configuration was changed outside the normal infrastructure-as-code workflow:

```text
Terraform:
maximum capacity = 40

AWS:
maximum capacity = 4
```

There was no corresponding change to the Terraform configuration.

From the perspective of the application, nothing was immediately wrong.

The existing nodes were healthy.

The cluster was available.

The data platform was operational.

The infrastructure had simply acquired a second source of truth.

And that is where drift becomes dangerous.

## Drift is not necessarily a failure

It is tempting to think of drift as:

> Terraform is broken because AWS is different.

That is not quite right.

Terraform is describing the desired state.

AWS is describing the current state.

If someone changes AWS directly, Terraform has not failed. The environment has simply moved away from the configuration that is supposed to manage it.

The dangerous condition is this:

```text
             Desired state
                  |
                  | Terraform
                  v
             max_size = 40


             Actual state
                  |
                  | AWS
                  v
             max_size = 4
```

Both values can remain valid.

Both systems can continue operating.

The failure only appears when another component depends on the difference not existing.

## The incident surfaced in Kubernetes

The Auto Scaling Group did not look like an application failure.

The application failure appeared later, when a data pipeline generated enough work to require additional Kubernetes nodes.

The sequence was approximately:

```text
Data pipeline starts
        |
        v
More pods are created
        |
        v
Kubernetes scheduler looks for capacity
        |
        v
Existing nodes become full
        |
        v
Cluster needs more nodes
        |
        v
Auto Scaling Group attempts to scale
        |
        v
maximum capacity = 4
        |
        v
No additional nodes can be added
        |
        v
Pods remain Pending
```

The important observation is that the Kubernetes scheduler was doing its job.

The data pipeline was doing its job.

The Auto Scaling Group was also doing exactly what it had been configured to do.

The problem was the configuration itself.

The platform had silently lost capacity.

## Why this took time to become visible

A change from 40 to 4 sounds catastrophic.

But if the workload normally runs comfortably on four nodes, the system can remain apparently healthy for a long time.

That creates a dangerous pattern:

```text
Manual change
     |
     v
No immediate symptom
     |
     v
Days/weeks pass
     |
     v
Workload demand increases
     |
     v
Capacity limit is reached
     |
     v
Application starts failing
```

This is one reason infrastructure drift deserves the same kind of attention as application configuration drift.

The time between the change and the failure makes the eventual incident harder to diagnose.

## What Terraform should tell us

Terraform's strength is the concept of a declared desired state.

A normal plan refreshes the current resource state and compares it with configuration.

For a drifted Auto Scaling Group, the plan can surface a difference along the lines of:

```text
~ resource "aws_autoscaling_group" "data_nodes" {

    ~ max_size = 4 -> 40

}
```

That output is valuable because it turns an invisible discrepancy into something reviewable.

The question then becomes:

**Why is the live value 4?**

There are several possible answers:

- someone made an emergency change,
- someone made an intentional change but forgot the code,
- another automation modified the resource,
- a separate team changed the resource,
- the Terraform configuration is no longer the correct desired state.

The important point is that drift detection should create a conversation before the discrepancy becomes an outage.

## Detecting drift is not the same as fixing drift

This distinction matters.

Suppose Terraform reports:

```text
AWS:
max_size = 4

Code:
max_size = 40
```

There are two possible desired outcomes.

### Option 1: Code is correct

Then the live infrastructure should be reconciled back to the declared configuration.

```text
Code: 40
     |
     v
terraform plan
     |
     v
terraform apply
     |
     v
AWS: 40
```

### Option 2: The infrastructure change was intentional

Then the code should be changed to represent the new desired state.

```text
AWS: 4
     |
     v
Review change
     |
     v
Update Terraform
     |
     v
Code: 4
```

Blindly applying Terraform is not drift management.

It is only reconciliation.

Drift management requires determining which state is supposed to win.

## The same problem exists with CloudFormation

Terraform is not unique here.

CloudFormation has the same fundamental challenge: infrastructure can be modified outside the template.

CloudFormation provides **drift detection** to compare supported resource properties in the live environment against the expected configuration represented by the stack.

Conceptually:

```text
CloudFormation template
        |
        v
Expected configuration
        |
        | compare
        v
Actual AWS resource
```

If an out-of-band change is detected, the stack can show that the resource has drifted.

For example:

```text
Template:
Desired configuration = X

Live resource:
Configuration = Y

Result:
DRIFTED
```

There is an important limitation: drift detection is not universal. CloudFormation only detects drift for supported resource types and properties, so a green drift result should not be interpreted as proof that every aspect of the environment matches the template.

The same principle applies to Terraform: detection depends on what is represented and managed by the tool.

## Drift should become a pipeline problem

The strongest improvement is to stop treating drift detection as something an engineer remembers to run after an incident.

Make it part of the platform lifecycle.

For Terraform, a practical model is:

```text
Git
 |
 v
Terraform configuration
 |
 v
CI
 |
 +---- terraform validate
 |
 +---- terraform plan
 |
 +---- policy checks
 |
 v
Approved change
 |
 v
AWS
```

Then add scheduled drift checks:

```text
Scheduled CI run
       |
       v
terraform plan
       |
       +---- no changes
       |
       +---- changes detected
                    |
                    v
               Alert / ticket
                    |
                    v
               Human review
```

The important part is the human review.

A drift detector should tell us that reality changed.

It should not automatically assume that the correct response is to overwrite reality.

## A useful Terraform pattern

A scheduled plan can be used as a lightweight drift signal.

For example:

```bash
terraform plan -detailed-exitcode
```

The exit codes give CI something useful to act on:

```text
0 = no changes
1 = error
2 = changes detected
```

That makes it possible to distinguish:

```text
Infrastructure is consistent
```

from:

```text
Infrastructure differs from declared configuration
```

without automatically applying anything.

For environments where the infrastructure state itself needs to be reconciled after investigation, Terraform also provides refresh-only operations. Those are useful when the intent is to update Terraform's state representation of the infrastructure rather than immediately changing the live infrastructure.

The key is to keep **detection**, **decision**, and **reconciliation** as separate steps.

## A useful CloudFormation pattern

CloudFormation drift detection can play a similar role for stacks managed by CloudFormation.

The operational workflow becomes:

```text
Scheduled drift detection
          |
          v
Stack drift status
          |
          +---- IN_SYNC
          |
          +---- DRIFTED
                    |
                    v
              Investigate
                    |
             +------+------+
             |             |
             v             v
       Template is      Live change
         correct         is desired
             |             |
             v             v
       Reconcile       Update template
```

Again, the tool is identifying a discrepancy.

The engineering process decides what that discrepancy means.

## The dangerous habit: "just change it in the console"

The AWS console is extremely useful.

It is also extremely easy to use.

That creates a familiar operational shortcut:

```text
Something needs changing
        |
        v
Open AWS console
        |
        v
Change value
        |
        v
Problem solved
```

Except the problem may only be solved in the short term.

The infrastructure repository still describes something else.

The next engineer reads the code and assumes the code represents reality.

A future Terraform plan may try to reverse the console change.

A future deployment may reintroduce the old configuration.

Or, worse, nobody notices until workload behavior depends on the changed value.

The real problem is not that someone used the console.

The problem is that the change did not become part of the system's source of truth.

## Emergency changes are different

Production systems sometimes require manual intervention.

That is not a failure of infrastructure-as-code.

If an incident requires changing an Auto Scaling Group from 4 to 40 immediately, waiting for a normal deployment pipeline may not be appropriate.

The important workflow is:

```text
Incident
   |
   v
Emergency change
   |
   v
Stabilize production
   |
   v
Record what changed
   |
   v
Update IaC
   |
   v
Plan / validate
   |
   v
Restore a single source of truth
```

The emergency path should be fast.

The reconciliation path should be mandatory.

Otherwise the emergency fix becomes permanent undocumented configuration.

## Drift management should include ownership

A useful drift process needs more than a tool.

It needs an owner.

When drift is detected, the team should be able to answer:

```text
What changed?
When did it change?
Who or what changed it?
Was it intentional?
What should the desired state be?
Does the code need to change?
Does the live resource need to change?
```

That turns drift from a mysterious infrastructure discrepancy into an auditable engineering event.

CloudTrail and other AWS audit sources can help answer the "who changed it?" question for AWS API activity, while the IaC repository provides the "what should it be?" side of the comparison.

Neither source alone tells the whole story.

## Prevention is better than detection

Drift detection is important, but preventing unauthorized changes is even better.

For critical infrastructure, organizations can combine:

- least-privilege IAM,
- separation of duties,
- deployment roles,
- CI/CD-based infrastructure changes,
- AWS audit logging,
- policy-as-code,
- scheduled drift detection,
- change management,
- documented emergency procedures.

The objective is not to make the console unusable.

The objective is to make the normal path obvious and the exceptional path auditable.

## The deeper lesson

The incident was triggered by a number.

Four instead of forty.

But the number was not the real problem.

The real problem was that the platform allowed two different versions of reality to exist:

```text
              Source of truth
                   |
                   v
             Terraform = 40


              Live system
                   |
                   v
                AWS = 4
```

The data pipeline eventually discovered the disagreement for us.

It discovered it in the most expensive possible way: by failing to get the capacity it expected.

That is why infrastructure drift is not merely a Terraform or CloudFormation housekeeping problem.

It is a reliability problem.

Infrastructure is part of the application's runtime behavior.

If the declared state says a platform can scale to 40 nodes, while the live platform can only scale to 4, that difference is not documentation debt.

It is an operational condition.

## A practical drift-management checklist

For infrastructure managed by Terraform or CloudFormation:

```text
[ ] Define the IaC repository as the desired-state source of truth
[ ] Minimize direct production changes
[ ] Make emergency changes explicitly auditable
[ ] Run scheduled drift detection
[ ] Alert on unexpected drift
[ ] Identify what changed and why
[ ] Decide whether code or infrastructure represents the intended state
[ ] Reconcile the two states
[ ] Validate after reconciliation
[ ] Record the incident when drift caused an operational impact
```

And most importantly:

> **Do not wait for production to tell you that your infrastructure and your code disagree.**

Production workloads are very good at finding configuration differences.

They are just not a particularly good drift-detection system.
