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

output "website_url" {
  description = "Temporary URL for The Drift Log"
  value       = "https://${aws_cloudfront_distribution.website.domain_name}"
}