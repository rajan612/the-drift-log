locals {
  domain_name = "thedriftlog.com"

  domain_names = toset([
    "thedriftlog.com",
    "www.thedriftlog.com"
  ])
}

data "aws_route53_zone" "website" {
  name         = local.domain_name
  private_zone = false
}
resource "aws_route53_record" "google_site_verification" {
  zone_id = data.aws_route53_zone.website.zone_id
  name    = local.domain_name
  type    = "TXT"
  ttl     = 300

  records = [
    "google-site-verification=qsTd90oZ1Ei2hsfMN9DgjNlJrDZ9Z8usuDVNtYfwC4w"
  ]
}
resource "aws_acm_certificate" "website" {
  domain_name = local.domain_name

  subject_alternative_names = [
    "www.${local.domain_name}"
  ]

  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "certificate_validation" {
  for_each = {
    for dvo in aws_acm_certificate.website.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = data.aws_route53_zone.website.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60

  records = [
    each.value.record
  ]
}

resource "aws_acm_certificate_validation" "website" {
  certificate_arn = aws_acm_certificate.website.arn

  validation_record_fqdns = [
    for record in aws_route53_record.certificate_validation :
    record.fqdn
  ]
}

resource "aws_route53_record" "website_ipv4" {
  for_each = local.domain_names

  zone_id = data.aws_route53_zone.website.zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.website.domain_name
    zone_id                = aws_cloudfront_distribution.website.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "website_ipv6" {
  for_each = local.domain_names

  zone_id = data.aws_route53_zone.website.zone_id
  name    = each.value
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.website.domain_name
    zone_id                = aws_cloudfront_distribution.website.hosted_zone_id
    evaluate_target_health = false
  }
}