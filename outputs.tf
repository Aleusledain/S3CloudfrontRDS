output "bucket_name" {
  value = aws_s3_bucket.site_bucket.id
}

output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.site.domain_name
}

output "site_url" {
  value       = var.domain_name != "" ? "https://${var.domain_name}" : "https://${aws_cloudfront_distribution.site.domain_name}"
  description = "Primary URL for the site"
}

output "acm_certificate_arn" {
  value       = var.domain_name != "" ? aws_acm_certificate.cert[0].arn : null
  description = "ACM certificate ARN (us-east-1)"
}
