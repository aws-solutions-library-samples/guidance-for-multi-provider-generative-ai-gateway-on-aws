# The ALB: internal by default, internet-facing in public mode. HTTP redirects
# to HTTPS with the customer's certificate; the allow_insecure_http trial serves
# plain HTTP (private only — enforced by variable validation). When an identity
# provider is set, the LiteLLM UI/sign-in paths sit behind the ALB's OIDC action
# in BOTH modes; API paths stay on LiteLLM's own authentication.

locals {
  serve_http = var.allow_insecure_http # private trial only, enforced in variables.tf

  # How long the ALB waits for any byte on a connection. It must exceed the
  # router's worst case for one non-streaming request, (1 + 2 timeout retries)
  # x 120 s = 360 s (templates/config-base.yaml.tftpl), plus a buffer, or long
  # completions get an ALB 504 instead of LiteLLM's own error. Independent of
  # the 120 s drain settings (container.tf). KEEPALIVE_TIMEOUT follows it.
  alb_idle_timeout_seconds = 600
}

resource "aws_lb" "this" {
  name                       = "${var.deployment_name}-alb"
  load_balancer_type         = "application"
  internal                   = !var.public_mode
  subnets                    = var.public_mode ? var.public_subnet_ids : var.private_subnet_ids
  security_groups            = [aws_security_group.alb.id]
  idle_timeout               = local.alb_idle_timeout_seconds
  drop_invalid_header_fields = true
  enable_deletion_protection = var.deletion_protection

  access_logs {
    bucket  = aws_s3_bucket.access_logs.bucket
    enabled = true
  }

  # The bucket policy must allow ELB log delivery before logging can be enabled.
  depends_on = [aws_s3_bucket_policy.access_logs]
}

resource "aws_lb_target_group" "litellm" {
  name                 = "${var.deployment_name}-${local.container.port}"
  port                 = local.container.port
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  target_type          = "ip"
  deregistration_delay = local.container.stop_timeout

  health_check {
    path                = local.container.health_check_path
    port                = tostring(local.container.port)
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
  }
}

# HTTPS on 443 (the normal case). Plain HTTP on 80 redirects to it.
resource "aws_lb_listener" "https" {
  count             = local.serve_http ? 0 : 1
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-Res-2021-06" # TLS 1.3 + forward-secret TLS 1.2 AEAD suites only
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.litellm.arn
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = local.serve_http ? [] : [1]
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  # Private trial without a certificate: plain HTTP straight to LiteLLM.
  dynamic "default_action" {
    for_each = local.serve_http ? [1] : []
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.litellm.arn
    }
  }
}

# Unconditional in both modes when an identity provider is set.
# The OIDC action only works for browsers, so it covers the UI and every
# interactive sign-in route of the pinned LiteLLM release (enumerated from its
# proxy routes; re-check on upgrade): the UI itself, LiteLLM's own SSO, the username/password
# logins (v1, v2, v3 and the v3 code exchange), the fallback login, invitation
# onboarding and the UI discovery document. API routes (including MCP OAuth for
# programmatic clients) stay on LiteLLM key authentication. Re-check this list
# when the image moves to another minor line.
# An ALB rule takes at most five path patterns, so the set spans several rules.
# It needs the HTTPS listener; identity_provider + allow_insecure_http is already
# rejected by variable validation.
locals {
  ui_oidc_paths = [
    "/ui", "/ui/*", "/sso/*", "/login*", "/v2/login",
    "/v3/login*", "/fallback/login", "/onboarding/*", "/.well-known/litellm-ui-config", "/litellm/.well-known/litellm-ui-config",
  ]
  ui_oidc_path_groups = var.identity_provider != null ? chunklist(local.ui_oidc_paths, 5) : []
}

resource "aws_lb_listener_rule" "ui_oidc" {
  count        = length(local.ui_oidc_path_groups)
  listener_arn = aws_lb_listener.https[0].arn
  priority     = 10 + count.index

  action {
    type = "authenticate-oidc"
    authenticate_oidc {
      issuer                     = var.identity_provider.issuer
      authorization_endpoint     = var.identity_provider.authorization_endpoint
      token_endpoint             = var.identity_provider.token_endpoint
      user_info_endpoint         = var.identity_provider.user_info_endpoint
      client_id                  = var.identity_provider.client_id
      client_secret              = data.aws_secretsmanager_secret_version.alb_oidc[0].secret_string
      on_unauthenticated_request = "authenticate"
      scope                      = "openid profile email"
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.litellm.arn
  }

  condition {
    path_pattern {
      values = local.ui_oidc_path_groups[count.index]
    }
  }
}

# The ALB API needs the client secret as a value, so it ends up in Terraform
# state. Keep the state encrypted and access-controlled (deploy.sh's bucket is).
data "aws_secretsmanager_secret_version" "alb_oidc" {
  count     = var.identity_provider != null ? 1 : 0
  secret_id = var.identity_provider.client_secret_arn
}

# DNS is optional. Without a hosted zone, clients use the ALB's own DNS name.
resource "aws_route53_record" "alb_alias" {
  count   = var.hosted_zone_id != null ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = var.record_name
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
