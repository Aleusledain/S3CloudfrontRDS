locals {
  name = "${var.project_name}"
  tags = merge(var.tags, { Project = var.project_name })
}

# ----------------------------
# S3: Content Bucket (private; CF-only access)
# ----------------------------
resource "aws_s3_bucket" "site_bucket" {
  bucket        = "${local.name}-content-${random_id.suffix.hex}"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site_bucket.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_versioning" "site" {
  bucket = aws_s3_bucket.site_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_encryption" "site" {
  bucket = aws_s3_bucket.site_bucket.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Optional: access logs bucket (for CF + S3)
resource "aws_s3_bucket" "logs" {
  count         = var.enable_logging ? 1 : 0
  bucket        = "${local.name}-logs-${random_id.suffix.hex}"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_ownership_controls" "logs" {
  count  = var.enable_logging ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id
  rule { object_ownership = "BucketOwnerPreferred" }
}

resource "aws_s3_bucket_versioning" "logs" {
  count  = var.enable_logging ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_encryption" "logs" {
  count  = var.enable_logging ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id
  rule { apply_server_side_encryption_by_default { sse_algorithm = "AES256" } }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  count                   = var.enable_logging ? 1 : 0
  bucket                  = aws_s3_bucket.logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ----------------------------
# CloudFront OAC to access S3 privately
# ----------------------------
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "${local.name}-oac"
  description                       = "OAC for ${local.name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ----------------------------
# ACM Certificate (us-east-1) + DNS validation (optional)
# ----------------------------
resource "aws_acm_certificate" "cert" {
  count                     = var.domain_name != "" ? 1 : 0
  provider                  = aws.us_east_1
  domain_name               = var.domain_name
  validation_method         = "DNS"
  tags                      = local.tags
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "cert_validation" {
  count   = var.domain_name != "" ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = aws_acm_certificate.cert[0].domain_validation_options[0].resource_record_name
  type    = aws_acm_certificate.cert[0].domain_validation_options[0].resource_record_type
  records = [aws_acm_certificate.cert[0].domain_validation_options[0].resource_record_value]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "cert" {
  count           = var.domain_name != "" ? 1 : 0
  provider        = aws.us_east_1
  certificate_arn = aws_acm_certificate.cert[0].arn
  validation_record_fqdns = [
    aws_route53_record.cert_validation[0].fqdn
  ]
}

# ----------------------------
# CloudFront Distribution
# ----------------------------
resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${local.name} distribution"
  default_root_object = "index.html"

  origin {
    domain_name = aws_s3_bucket.site_bucket.bucket_regional_domain_name
    origin_id   = "s3-origin-${aws_s3_bucket.site_bucket.id}"

    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-origin-${aws_s3_bucket.site_bucket.id}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]

    compress = true

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
  }

  price_class = "PriceClass_100" # cheapest global option

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    acm_certificate_arn = var.domain_name != "" ? aws_acm_certificate_validation.cert[0].certificate_arn : null
    cloudfront_default_certificate = var.domain_name == "" ? true : false
    minimum_protocol_version       = "TLSv1.2_2021"
    ssl_support_method             = var.domain_name != "" ? "sni-only" : null
  }

  dynamic "logging_config" {
    for_each = var.enable_logging ? [1] : []
    content {
      bucket = "${aws_s3_bucket.logs[0].bucket_domain_name}"
      prefix = "cloudfront/"
      include_cookies = false
    }
  }

  tags = local.tags
}

# Allow CloudFront (via OAC) to read from the bucket
data "aws_caller_identity" "current" {}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontServicePrincipalReadOnly"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = ["s3:GetObject"]
        Resource  = "${aws_s3_bucket.site_bucket.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/${aws_cloudfront_distribution.site.id}"
          }
        }
      }
    ]
  })
  depends_on = [aws_cloudfront_distribution.site]
}

# ----------------------------
# Route 53 alias to CloudFront (optional)
# ----------------------------
# CloudFront hosted zone ID is constant
locals {
  cloudfront_hosted_zone_id = "Z2FDTNDATAQYW2"
}

resource "aws_route53_record" "alias" {
  count   = var.domain_name != "" ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = local.cloudfront_hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "alias_ipv6" {
  count   = var.domain_name != "" ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "AAAA"
  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = local.cloudfront_hosted_zone_id
    evaluate_target_health = false
  }
}

# ----------------------------
# WAF (optional, global scope)
# ----------------------------
resource "aws_wafv2_web_acl" "cf_waf" {
  count    = var.enable_waf ? 1 : 0
  provider = aws.us_east_1
  name     = "${local.name}-waf"
  scope    = "CLOUDFRONT"
  default_action { allow {} }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1
    statement { managed_rule_group_statement { vendor_name = "AWS"; name = "AWSManagedRulesCommonRuleSet" } }
    visibility_config { cloudwatch_metrics_enabled = true; metric_name = "${local.name}-waf-common"; sampled_requests_enabled = true }
    override_action { none {} }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2
    statement { managed_rule_group_statement { vendor_name = "AWS"; name = "AWSManagedRulesKnownBadInputsRuleSet" } }
    visibility_config { cloudwatch_metrics_enabled = true; metric_name = "${local.name}-waf-badinputs"; sampled_requests_enabled = true }
    override_action { none {} }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-waf"
    sampled_requests_enabled   = true
  }

  tags = local.tags
}

resource "aws_wafv2_web_acl_association" "cf_assoc" {
  count        = var.enable_waf ? 1 : 0
  provider     = aws.us_east_1
  resource_arn = "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/${aws_cloudfront_distribution.site.id}"
  web_acl_arn  = aws_wafv2_web_acl.cf_waf[0].arn
}

# ----------------------------
# AWS Budget (optional)
# ----------------------------
resource "aws_budgets_budget" "monthly" {
  count       = var.monthly_budget_usd > 0 ? 1 : 0
  name        = "${local.name}-monthly-budget"
  budget_type = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_tax       = true
    include_subscription = true
    use_amortized     = false
  }

  notification {
    comparison_operator = "GREATER_THAN"
    threshold           = 80
    threshold_type      = "PERCENTAGE"
    notification_type   = "FORECASTED"

    subscriber_email_addresses = [ "billing@invalid.local" ] # TODO: replace with your email
  }

  tags = local.tags
}

# Random suffix to make bucket names globally unique
resource "random_id" "suffix" {
  byte_length = 4
}
