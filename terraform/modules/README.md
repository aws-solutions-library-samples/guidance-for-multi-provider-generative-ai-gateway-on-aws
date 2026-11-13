# Child modules

Child modules called by the two root modules:

- `observability/`: CloudWatch alarms, the gateway dashboard and the encrypted SNS alarm topic; called by
  `terraform/app`.
- `rollout/`: uploads the rendered LiteLLM config and runs the schema migration before the ECS service rolls;
  called by `terraform/app`.
- `vpn/`: the optional demo AWS Client VPN; called by `terraform/foundation` when `create_vpn = true`.

Test files of `terraform/app` must contain `override_module { target = module.rollout }`: its `local-exec`
provisioners run even for an overridden resource and would call AWS during `terraform test`.
