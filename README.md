# Static Site on AWS with Terraform (S3 + CloudFront + optional Route 53/ACM/WAF)

## Prereqs
- Terraform >= 1.5, AWS CLI configured (`aws configure`)
- (Optional) A domain hosted in Route 53 if you want a custom URL + HTTPS

## Configure
Edit `variables.tf` via a `terraform.tfvars` file, e.g.:

aws_region   = "us-east-1"
project_name = "mc-static"
domain_name  = "www.example.com"     # leave blank to skip DNS + cert
hosted_zone_id = "Z1234567890ABCDE"  # required if domain_name set
enable_waf     = true
enable_logging = true
monthly_budget_usd = 10
tags = { Owner = "McIntyre", Env = "dev" }

## Deploy
terraform init
terraform plan
terraform apply

## Upload your site
# Replace with your build output folder (must include index.html)
aws s3 sync ./site/ s3://$(terraform output -raw bucket_name) --delete

## Visit your site
- With custom domain: https://<domain_name>
- Without custom domain: https://<cloudfront_domain_name>

## Clean up
terraform destroy
