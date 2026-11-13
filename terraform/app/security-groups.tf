# ALB and task security groups. Data-store access (RDS, Redis) is NOT granted
# here: the foundation exports data_ingress_security_group_id, whose membership
# grants it, and the tasks simply join that group (ecs.tf).

resource "aws_security_group" "ecs_service" {
  name        = "${var.deployment_name}-service-sg"
  description = "LiteLLM Fargate tasks"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Outbound to LLM providers, AWS APIs and the licence server"
  }
}

resource "aws_security_group_rule" "service_from_alb" {
  type                     = "ingress"
  from_port                = local.container.port
  to_port                  = local.container.port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ecs_service.id
  source_security_group_id = aws_security_group.alb.id
  description              = "ALB to LiteLLM tasks"
}

resource "aws_security_group" "alb" {
  name_prefix = "${var.deployment_name}-alb-"
  description = "LiteLLM ALB"
  vpc_id      = var.vpc_id

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.deployment_name}-alb-sg"
  }
}

locals {
  # Public: the internet (WAF in front). Private: the VPC, or the client ranges
  # given (VPN, Direct Connect, Transit Gateway) — never all of RFC 1918.
  alb_ingress_cidrs = var.public_mode ? ["0.0.0.0/0"] : (length(var.client_cidrs) > 0 ? var.client_cidrs : [var.vpc_cidr])
  alb_ingress_ports = var.allow_insecure_http ? [80] : [80, 443]
}

resource "aws_vpc_security_group_ingress_rule" "alb" {
  for_each = { for pair in setproduct(local.alb_ingress_cidrs, local.alb_ingress_ports) : "${pair[0]}-${pair[1]}" => pair }

  security_group_id = aws_security_group.alb.id
  description       = each.value[1] == 80 && !var.allow_insecure_http ? "HTTP, redirected to HTTPS" : "Clients to the gateway"
  cidr_ipv4         = each.value[0]
  ip_protocol       = "tcp"
  from_port         = each.value[1]
  to_port           = each.value[1]
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_sg" {
  for_each = toset(concat(var.client_security_group_ids, var.vpn_security_group_id != null ? [var.vpn_security_group_id] : []))

  security_group_id            = aws_security_group.alb.id
  description                  = "Clients by security group (for example the demo Client VPN)"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = var.allow_insecure_http ? 80 : 443
  to_port                      = var.allow_insecure_http ? 80 : 443
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = aws_security_group.alb.id
  description                  = "ALB to LiteLLM tasks"
  referenced_security_group_id = aws_security_group.ecs_service.id
  ip_protocol                  = "tcp"
  from_port                    = local.container.port
  to_port                      = local.container.port
}

# ALB OIDC: the load balancer itself calls the IdP's token and user-info
# endpoints over HTTPS. Those are internet hosts whose addresses are not known
# in advance, so egress is open on 443 only, and only when an IdP is set.
resource "aws_vpc_security_group_egress_rule" "alb_to_idp" {
  count             = var.identity_provider != null ? 1 : 0
  security_group_id = aws_security_group.alb.id
  description       = "ALB OIDC to the identity provider (token and user-info endpoints)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

