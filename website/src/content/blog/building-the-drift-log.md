---
title: 'Building The Drift Log: From Terraform State to a Production Static Site on AWS'
description: 'How I built a small engineering portfolio with Terraform, a private S3 origin, CloudFront OAC, GitHub OIDC, ACM, Route 53, and automated deployment.'
pubDate: '2026-09-27T20:59:00-04:00'
---

A portfolio site is easy to make complicated.

I wanted **The Drift Log** to stay small enough to understand, cheap enough to forget about, and production-shaped enough to exercise the same engineering habits I expect from larger systems.

The result is a static Astro site deployed through a deliberately boring AWS path:

```text
GitHub
  ↓
GitHub Actions + OIDC
  ↓
S3 private origin
  ↓
CloudFront + OAC
  ↓
Route 53 + ACM
  ↓
thedriftlog.com
```

The interesting part is not the website. It is everything around the website: state, identity, TLS, caching, DNS, deployment automation, and making sure the origin is not accidentally public.

## Start with state before infrastructure

The first resource I created was not the website bucket. It was the Terraform state backend.

The state bucket is versioned, encrypted, blocked from public access, and protected from accidental destruction. Terraform uses the S3 backend with native state locking:

```hcl
terraform {
  backend "s3" {
    bucket       = "example-tfstate-bucket"
    key          = "prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

That decision matters because the infrastructure repository is now usable from more than one workstation or CI runner without pretending local state is a collaboration strategy.

The general rule I try to follow is simple:

> If the system is going to be managed as infrastructure-as-code, the state path should be intentional before the rest of the infrastructure becomes important.

## Keep the S3 origin private

The site files live in S3, but the bucket is not a public website bucket.

Public access is blocked at the bucket level. CloudFront reads objects using **Origin Access Control (OAC)** and SigV4 signing.

That gives me a cleaner trust boundary:

```text
Internet
   ↓
CloudFront
   ↓ signed origin request
Private S3 bucket
```

The bucket policy only grants `s3:GetObject` to the CloudFront service principal when the request comes from the expected distribution ARN.

Conceptually:

```hcl
statement {
  effect = "Allow"

  principals {
    type        = "Service"
    identifiers = ["cloudfront.amazonaws.com"]
  }

  actions   = ["s3:GetObject"]
  resources = ["${aws_s3_bucket.website.arn}/*"]

  condition {
    test     = "StringEquals"
    variable = "AWS:SourceArn"
    values   = [aws_cloudfront_distribution.website.arn]
  }
}
```

There is also an explicit deny for insecure transport. Defense in depth is cheap when the policy is already being managed in code.

## Static sites still have routing problems

Astro generates clean routes such as:

```text
/blog/
/about/
```

S3 REST origins, however, do not behave like an application server that automatically translates every clean path into an `index.html`.

Instead of making the S3 bucket public and using the static website endpoint, I kept the private REST origin and attached a lightweight CloudFront Function.

The request rewrite is intentionally tiny:

```javascript
function handler(event) {
  var request = event.request;
  var uri = request.uri;

  if (uri.endsWith('/')) {
    request.uri += 'index.html';
  } else if (!uri.includes('.')) {
    request.uri += '/index.html';
  }

  return request;
}
```

That lets `/blog` resolve to `/blog/index.html` while normal assets such as `/resume.pdf` remain untouched.

Small edge logic solved the routing problem without weakening the origin security model.

## Deployment without long-lived AWS credentials

The repository deploys through GitHub Actions.

I did not want AWS access keys stored as GitHub secrets, so the workflow uses GitHub's OIDC identity provider and assumes a narrowly scoped AWS IAM role.

The trust path looks like this:

```text
GitHub workflow
      ↓ OIDC token
AWS IAM trust policy
      ↓ AssumeRoleWithWebIdentity
Short-lived AWS credentials
      ↓
S3 sync + CloudFront invalidation
```

The deployment role can do only what the workflow needs:

- list the website bucket,
- read/write/delete website objects,
- create an invalidation for the specific CloudFront distribution.

That is enough to deploy the site without creating another permanent credential that someone has to rotate later.

The deployment itself is deliberately uncomplicated:

```yaml
- name: Deploy site to S3
  run: aws s3 sync dist/ s3://example-site-bucket --delete

- name: Invalidate CloudFront cache
  run: aws cloudfront create-invalidation \
    --distribution-id EXAMPLE \
    --paths "/*"
```

A push to `master` that changes `website/**` builds the Astro site, assumes the AWS role, syncs the generated files, and invalidates the CDN.

## Put the domain into Terraform too

Once the domain existed, I kept the registration itself outside Terraform but managed the DNS records and certificate through Terraform.

The existing public Route 53 hosted zone is discovered as a data source. Terraform then manages:

- an ACM certificate for the apex domain,
- a SAN for `www`,
- DNS validation CNAMEs,
- Route 53 `A` aliases,
- Route 53 `AAAA` aliases,
- CloudFront alternate domain names,
- the CloudFront viewer certificate.

CloudFront requires its ACM certificate in `us-east-1`, which is also the region used by this stack.

The certificate configuration is straightforward:

```hcl
resource "aws_acm_certificate" "website" {
  domain_name = "thedriftlog.com"

  subject_alternative_names = [
    "www.thedriftlog.com"
  ]

  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}
```

The CloudFront distribution then uses the validated certificate with modern TLS:

```hcl
viewer_certificate {
  acm_certificate_arn      = aws_acm_certificate_validation.website.certificate_arn
  ssl_support_method       = "sni-only"
  minimum_protocol_version = "TLSv1.2_2021"
}
```

## Validate before celebrating

The deployment was not considered finished because Terraform said `Apply complete`.

I checked each layer independently:

```bash
dig +short thedriftlog.com
dig +short www.thedriftlog.com
curl -I https://thedriftlog.com
curl -I https://www.thedriftlog.com
curl -I https://www.thedriftlog.com/resume.pdf
```

One useful reminder came from DNS caching.

Public resolvers were already returning the new apex record while my local resolver was still returning the earlier negative result. Querying `1.1.1.1` and `8.8.8.8` directly separated an AWS problem from a local DNS-cache problem.

That distinction saved me from "fixing" infrastructure that was already correct.

## What I would improve next

The current design is intentionally small, but there are obvious next steps:

1. Redirect `www.thedriftlog.com` to the apex domain instead of serving the same content on both hostnames.
2. Add a CloudFront response-headers policy for security headers.
3. Add infrastructure validation in CI, not only website deployment.
4. Add more useful cache behavior instead of invalidating `/*` after every deploy.
5. Add observability only where it answers a real question.

The last point is important.

It is very easy to turn a small static site into a museum of cloud services. That is not the goal.

The goal is a system whose architecture can be explained, reproduced, and changed safely.

That is also the point of The Drift Log.
