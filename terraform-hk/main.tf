# Global-partition deployment: CloudFront default domain (*.cloudfront.net, publicly
# trusted cert, no ICP needed) -> VPC origin -> private EC2 with no public IP.
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
  default_tags {
    tags = { Project = "orca-selfhost-relay" }
  }
}

variable "region" {
  type    = string
  default = "ap-east-1"
}

variable "aws_profile" {
  type    = string
  default = "default"
}

variable "instance_type" {
  type    = string
  default = "t4g.small"
}

variable "owner_email" {
  type = string
}

variable "private_subnet_cidr" {
  type    = string
  default = "172.31.128.0/24"
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

resource "random_password" "owner" {
  length  = 24
  special = false
}

# ---------- bundle bucket (filled by ../build-artifacts.sh) ----------
resource "aws_s3_bucket" "bundle" {
  bucket = "orca-selfhost-relay-${data.aws_caller_identity.current.account_id}-${var.region}"
}

resource "aws_s3_bucket_public_access_block" "bundle" {
  bucket                  = aws_s3_bucket.bundle.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "bundle" {
  bucket = aws_s3_bucket.bundle.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ---------- network: private subnet, only S3 + SSM endpoints ----------
data "aws_vpc" "default" {
  default = true
}

resource "aws_subnet" "private" {
  vpc_id                  = data.aws_vpc.default.id
  cidr_block              = var.private_subnet_cidr
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = false
  tags                    = { Name = "orca-selfhost-relay-private" }
}

resource "aws_route_table" "private" {
  vpc_id = data.aws_vpc.default.id
  tags   = { Name = "orca-selfhost-relay-private" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = data.aws_vpc.default.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = { Name = "orca-selfhost-relay-s3" }
}

resource "aws_security_group" "endpoints" {
  name        = "orca-selfhost-relay-endpoints"
  description = "SSM interface endpoints, reachable only from the relay instance"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "HTTPS from relay instance"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.instance.id]
  }
}

resource "aws_vpc_endpoint" "ssm" {
  for_each            = toset(["ssm", "ssmmessages", "ec2messages"])
  vpc_id              = data.aws_vpc.default.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  tags                = { Name = "orca-selfhost-relay-${each.key}" }
}

resource "aws_security_group" "instance" {
  name        = "orca-selfhost-relay-instance"
  description = "Orca relay instance: relay and auth ports from CloudFront VPC origins only"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# CloudFront creates this group in the VPC with the first VPC origin; allowing it
# (instead of the origin-facing prefix list) admits only VPC-origin traffic.
data "aws_security_group" "cloudfront_vpc_origins" {
  vpc_id     = data.aws_vpc.default.id
  name       = "CloudFront-VPCOrigins-Service-SG"
  depends_on = [aws_cloudfront_vpc_origin.relay, aws_cloudfront_vpc_origin.auth]
}

resource "aws_vpc_security_group_ingress_rule" "from_cloudfront" {
  for_each                     = { relay = 8080, auth = 8787 }
  security_group_id            = aws_security_group.instance.id
  referenced_security_group_id = data.aws_security_group.cloudfront_vpc_origins.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  description                  = "${each.key} from CloudFront VPC origins"
}

# ---------- instance role ----------
resource "aws_iam_role" "relay" {
  name = "orca-selfhost-relay-${var.region}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.${data.aws_partition.current.dns_suffix}" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.relay.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "host" {
  name = "orca-selfhost-host"
  role = aws_iam_role.relay.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "s3:GetObject", Resource = "${aws_s3_bucket.bundle.arn}/*" },
      { Effect = "Allow", Action = "ssm:GetParameter", Resource = aws_ssm_parameter.relay_domain.arn }
    ]
  })
}

resource "aws_iam_instance_profile" "relay" {
  name = "orca-selfhost-relay-${var.region}"
  role = aws_iam_role.relay.name
}

# ---------- instance (no public IP) ----------
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  domain_param = "/orca-selfhost-relay/domain"
  site_env = join("\n", [
    "RELAY_DOMAIN_PARAM=${local.domain_param}",
    "OWNER_EMAIL=${var.owner_email}",
    "OWNER_PASSWORD=${random_password.owner.result}",
    "BUNDLE_S3_URI=s3://${aws_s3_bucket.bundle.id}/orca-selfhost.tar.gz",
    "AWS_REGION=${var.region}",
    ""
  ])
  cloud_config = {
    write_files = [
      { path = "/etc/orca-selfhost/site.env", content = local.site_env, permissions = "0600" },
      {
        path        = "/usr/local/sbin/orca-selfhost-install"
        encoding    = "b64"
        content     = filebase64("${path.module}/../host/install.sh")
        permissions = "0755"
      }
    ]
    # Bundle, endpoints and the domain parameter may lag first boot; retry for a while.
    runcmd = [["bash", "-c", "for i in $(seq 1 60); do /usr/local/sbin/orca-selfhost-install && break; sleep 30; done > /var/log/orca-selfhost-install.log 2>&1"]]
  }
}

resource "aws_instance" "relay" {
  ami                         = data.aws_ssm_parameter.al2023_arm64.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.private.id
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.relay.name
  vpc_security_group_ids      = [aws_security_group.instance.id]
  user_data_base64            = base64encode("#cloud-config\n${yamlencode(local.cloud_config)}")

  metadata_options {
    http_tokens = "required"
  }
  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }
  lifecycle {
    ignore_changes = [ami, tags["Patch Group"], tags_all["Patch Group"]]
  }
  depends_on = [aws_vpc_endpoint.s3, aws_vpc_endpoint.ssm]
  tags       = { Name = "orca-selfhost-relay" }
}

# ---------- CloudFront ----------
resource "aws_cloudfront_vpc_origin" "relay" {
  vpc_origin_endpoint_config {
    name                   = "orca-selfhost-relay"
    arn                    = aws_instance.relay.arn
    http_port              = 8080
    https_port             = 443
    origin_protocol_policy = "http-only"
    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }
}

resource "aws_cloudfront_vpc_origin" "auth" {
  vpc_origin_endpoint_config {
    name                   = "orca-selfhost-auth"
    arn                    = aws_instance.relay.arn
    http_port              = 8787
    https_port             = 443
    origin_protocol_policy = "http-only"
    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }
}

# Never cache, but keep Authorization: it is only forwarded when it is part of the cache key.
resource "aws_cloudfront_cache_policy" "passthrough" {
  name        = "orca-selfhost-relay-passthrough"
  min_ttl     = 0
  default_ttl = 0
  max_ttl     = 1
  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = false
    enable_accept_encoding_brotli = false
    headers_config {
      header_behavior = "whitelist"
      headers {
        items = ["Authorization"]
      }
    }
    cookies_config {
      cookie_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "all"
    }
  }
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_function" "block_admin" {
  name    = "orca-selfhost-relay-block-admin"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = <<-EOT
    function handler(event) {
      if (event.request.uri.startsWith('/v1/admin/')) {
        return { statusCode: 404, statusDescription: 'Not Found' };
      }
      return event.request;
    }
  EOT
}

locals {
  all_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
}

resource "aws_cloudfront_distribution" "relay" {
  enabled         = true
  comment         = "Orca self-hosted relay + auth"
  http_version    = "http1.1"
  is_ipv6_enabled = true
  price_class     = "PriceClass_All"

  origin {
    origin_id   = "relay"
    domain_name = aws_instance.relay.private_dns
    vpc_origin_config {
      vpc_origin_id            = aws_cloudfront_vpc_origin.relay.id
      origin_read_timeout      = 60
      origin_keepalive_timeout = 60
    }
  }

  origin {
    origin_id   = "auth"
    domain_name = aws_instance.relay.private_dns
    vpc_origin_config {
      vpc_origin_id            = aws_cloudfront_vpc_origin.auth.id
      origin_read_timeout      = 30
      origin_keepalive_timeout = 5
    }
  }

  dynamic "ordered_cache_behavior" {
    for_each = ["/v1/desktop/*", "/.well-known/*"]
    content {
      path_pattern             = ordered_cache_behavior.value
      target_origin_id         = "auth"
      viewer_protocol_policy   = "https-only"
      allowed_methods          = local.all_methods
      cached_methods           = ["GET", "HEAD"]
      compress                 = false
      cache_policy_id          = aws_cloudfront_cache_policy.passthrough.id
      origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    }
  }

  default_cache_behavior {
    target_origin_id         = "relay"
    viewer_protocol_policy   = "https-only"
    allowed_methods          = local.all_methods
    cached_methods           = ["GET", "HEAD"]
    compress                 = false
    cache_policy_id          = aws_cloudfront_cache_policy.passthrough.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.block_admin.arn
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "aws_ssm_parameter" "relay_domain" {
  name  = local.domain_param
  type  = "String"
  value = aws_cloudfront_distribution.relay.domain_name
}

output "relay_url" {
  value = "https://${aws_cloudfront_distribution.relay.domain_name}"
}

output "instance_id" {
  value = aws_instance.relay.id
}

output "bundle_bucket" {
  value = aws_s3_bucket.bundle.id
}

output "owner_password" {
  value     = random_password.owner.result
  sensitive = true
}
