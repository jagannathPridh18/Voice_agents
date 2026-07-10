variable "domain_name" {
  type = string
}

variable "route53_zone_id" {
  type    = string
  default = ""
}

# When true, ACM validation + the app record are managed in Route53. When false
# (external DNS, e.g. Cloudflare), Terraform creates the cert and waits for it to
# be validated by a record you add at your DNS provider — the validation record
# is exposed via the domain_validation_options output.
variable "create_route53_records" {
  type    = bool
  default = true
}

# When false, the cert is created but not waited-on (used in HTTP-only mode, or
# before the external DNS validation record has been added).
variable "create_validation" {
  type    = bool
  default = true
}

resource "aws_acm_certificate" "this" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validation" {
  for_each = var.create_route53_records ? {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id = var.route53_zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60

  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count           = var.create_validation ? 1 : 0
  certificate_arn = aws_acm_certificate.this.arn
  # Route53 path passes the FQDNs it just created; external-DNS path passes
  # nothing and simply waits for the cert to reach ISSUED once you add the
  # record at your provider.
  validation_record_fqdns = var.create_route53_records ? [for r in aws_route53_record.validation : r.fqdn] : null
}

output "certificate_arn" {
  # Validated ARN when we waited; otherwise the (possibly-pending) cert ARN.
  value = var.create_validation ? aws_acm_certificate_validation.this[0].certificate_arn : aws_acm_certificate.this.arn
}

output "domain_validation_options" {
  description = "DNS record(s) to add at your provider (Cloudflare) to validate the cert."
  value = [for o in aws_acm_certificate.this.domain_validation_options : {
    name  = o.resource_record_name
    type  = o.resource_record_type
    value = o.resource_record_value
  }]
}
