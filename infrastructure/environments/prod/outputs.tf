output "website_bucket_name" {
  description = "Private S3 bucket containing The Drift Log"
  value       = aws_s3_bucket.website.bucket
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID"
  value       = aws_cloudfront_distribution.website.id
}

output "cloudfront_domain_name" {
  description = "CloudFront hostname"
  value       = aws_cloudfront_distribution.website.domain_name
}

output "route53_hosted_zone_id" {
  description = "Route 53 hosted zone ID for The Drift Log"
  value       = data.aws_route53_zone.website.zone_id
}

output "acm_certificate_arn" {
  description = "ACM certificate ARN for The Drift Log"
  value       = aws_acm_certificate.website.arn
}

output "website_url" {
  description = "Primary URL for The Drift Log"
  value       = "https://thedriftlog.com"
}

output "www_website_url" {
  description = "WWW URL for The Drift Log"
  value       = "https://www.thedriftlog.com"
}