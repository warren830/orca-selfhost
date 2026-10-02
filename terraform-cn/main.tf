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
  default = "cn-northwest-1"
}

variable "aws_profile" {
  type    = string
  default = "ychchen-china"
}

variable "instance_type" {
  type    = string
  default = "t4g.small"
}

variable "relay_domain" {
  type        = string
  default     = "relay.yingchu.cloud"
  description = "ICP-filed domain served by CloudFront; auth and relay share it"
}

variable "owner_email" {
  type = string
}

variable "private_subnet_cidr" {
  type    = string
  default = "172.31.128.0/24"
}

variable "enable_cdn" {
  type        = bool
  default     = false
  description = "Create the CloudFront distribution; needs an IAM server certificate named orca-relay-* (see ./renew-cert.sh)"
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

resource "random_password" "owner" {
  length  = 24
  special = false
}

# CloudFront sends this header to the origin; the ALB rejects anything without it,
# so other CloudFront distributions (which share the origin-facing prefix list) cannot reach us.
resource "random_password" "origin_verify" {
  length  = 40
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

# ---------- network: private subnet with only S3 + SSM endpoints ----------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

resource "aws_subnet" "private" {
  vpc_id                  = data.aws_vpc.default.id
  cidr_block              = var.private_subnet_cidr
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = false
  tags                    = { Name = "orca-selfhost-relay-private" }
}

# No internet route: the instance only reaches S3 (gateway) and SSM (interface endpoints).
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

# ---------- load balancer: reachable only from CloudFront ----------
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name        = "orca-selfhost-relay-alb"
  description = "Orca relay ALB: HTTP from CloudFront origin-facing ranges only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "HTTP from CloudFront"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }
}

resource "aws_security_group" "instance" {
  name        = "orca-selfhost-relay-instance"
  description = "Orca relay instance: relay and auth ports from the ALB only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "relay from ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  ingress {
    description     = "auth from ALB"
    from_port       = 8787
    to_port         = 8787
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "relay" {
  name               = "orca-selfhost-relay"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.public.ids
  # Relay sockets are long-lived; keep idle ones open well past heartbeat gaps.
  idle_timeout               = 3600
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "relay" {
  name     = "orca-selfhost-relay"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id
  health_check {
    path    = "/health"
    matcher = "200"
  }
}

resource "aws_lb_target_group" "auth" {
  name     = "orca-selfhost-auth"
  port     = 8787
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id
  health_check {
    path    = "/health"
    matcher = "200"
  }
}

resource "aws_lb_target_group_attachment" "relay" {
  target_group_arn = aws_lb_target_group.relay.arn
  target_id        = aws_instance.relay.id
}

resource "aws_lb_target_group_attachment" "auth" {
  target_group_arn = aws_lb_target_group.auth.arn
  target_id        = aws_instance.relay.id
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.relay.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "forbidden"
      status_code  = "403"
    }
  }
}

resource "aws_lb_listener_rule" "admin_blocked" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10
  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "not found"
      status_code  = "404"
    }
  }
  condition {
    path_pattern {
      values = ["/v1/admin/*"]
    }
  }
}

resource "aws_lb_listener_rule" "auth" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 20
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.auth.arn
  }
  condition {
    http_header {
      http_header_name = "X-Orca-Origin-Verify"
      values           = [random_password.origin_verify.result]
    }
  }
  condition {
    path_pattern {
      values = ["/v1/desktop/*", "/.well-known/*"]
    }
  }
}

resource "aws_lb_listener_rule" "relay" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 30
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.relay.arn
  }
  condition {
    http_header {
      http_header_name = "X-Orca-Origin-Verify"
      values           = [random_password.origin_verify.result]
    }
  }
}

# ---------- instance role: SSM + read the bundle ----------
resource "aws_iam_role" "relay" {
  name = "orca-selfhost-relay"
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

resource "aws_iam_role_policy" "bundle_read" {
  name = "bundle-read"
  role = aws_iam_role.relay.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "s3:GetObject", Resource = "${aws_s3_bucket.bundle.arn}/*" }]
  })
}

resource "aws_iam_instance_profile" "relay" {
  name = "orca-selfhost-relay"
  role = aws_iam_role.relay.name
}

# ---------- instance (no public IP) ----------
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  site_env = join("\n", [
    "RELAY_DOMAIN=${var.relay_domain}",
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
    # The bundle or the endpoints may not be ready at first boot; retry for a while.
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
    # "Patch Group" is set by the account's patch automation, not by us.
    ignore_changes = [ami, tags["Patch Group"], tags_all["Patch Group"]]
  }
  depends_on = [aws_vpc_endpoint.s3, aws_vpc_endpoint.ssm]
  tags       = { Name = "orca-selfhost-relay" }
}

# ---------- CloudFront (China) ----------
data "aws_iam_server_certificate" "relay" {
  count       = var.enable_cdn ? 1 : 0
  name_prefix = "orca-relay-"
  latest      = true
}

resource "aws_cloudfront_distribution" "relay" {
  count           = var.enable_cdn ? 1 : 0
  enabled         = true
  comment         = "Orca self-hosted relay + auth"
  aliases         = [var.relay_domain]
  http_version    = "http1.1"
  is_ipv6_enabled = false

  origin {
    origin_id   = "alb"
    domain_name = aws_lb.relay.dns_name
    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "http-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 60
      origin_keepalive_timeout = 60
    }
    custom_header {
      name  = "X-Orca-Origin-Verify"
      value = random_password.origin_verify.result
    }
  }

  default_cache_behavior {
    target_origin_id       = "alb"
    viewer_protocol_policy = "https-only"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    compress               = false
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
    # Forwarding every header disables caching and carries the WebSocket upgrade headers.
    forwarded_values {
      query_string = true
      headers      = ["*"]
      cookies {
        forward = "all"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    iam_certificate_id       = data.aws_iam_server_certificate.relay[0].id
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2018"
  }

  lifecycle {
    # ./renew-cert.sh rotates the certificate in place.
    ignore_changes = [viewer_certificate]
  }
}

output "instance_id" {
  value = aws_instance.relay.id
}

output "bundle_bucket" {
  value = aws_s3_bucket.bundle.id
}

output "alb_dns_name" {
  value = aws_lb.relay.dns_name
}

output "cloudfront_domain_name" {
  value = var.enable_cdn ? aws_cloudfront_distribution.relay[0].domain_name : null
}

output "cloudfront_distribution_id" {
  value = var.enable_cdn ? aws_cloudfront_distribution.relay[0].id : null
}

output "owner_password" {
  value     = random_password.owner.result
  sensitive = true
}
