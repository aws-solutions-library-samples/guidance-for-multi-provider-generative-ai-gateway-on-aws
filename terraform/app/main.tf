# The app root module, by file:
#   container.tf       the ONE place container settings live (image, port, env,
#                      secrets, health check, stop timeout) — any non-ECS runtime can mirror it
#   config.tf          LiteLLM config rendered (templatefile) and uploaded to S3;
#                      its hash rolls the tasks; plan-time warning checks
#   alb.tf             ALB (internal by default), listeners, OIDC sign-in, DNS alias
#   waf.tf             WAF, public mode only
#   security-groups.tf ALB and task security groups
#   ecs.tf             cluster, service + migration task definitions, migration
#                      gate, auto scaling
#   iam.tf             least-privilege task and execution roles
#   logs.tf            CloudWatch log group, ALB access-log and request-log buckets
#   observability.tf   alarms, dashboard and alarm topic (terraform/modules/observability)
# No custom code in the request path: no sidecars, no wrappers, no LiteLLM patches.
