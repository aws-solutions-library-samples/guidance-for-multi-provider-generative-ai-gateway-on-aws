# The two steps an app apply runs outside Terraform's providers, in order, with
# the AWS CLI and the deploying credentials:
#
# 1. Upload the rendered config to its content-addressed key. Earlier keys are
#    never deleted (an aws_s3_object would delete the previous key on change),
#    so every task-definition revision, including a circuit-breaker rollback,
#    still loads the config it was deployed with.
# 2. Run the schema migration as a one-off ECS task and fail the apply unless
#    it exits 0. LiteLLM's health endpoints report healthy on an unmigrated
#    database, so neither the circuit breaker
#    nor the ALB health check would catch a missed migration; the service
#    depends on this module and only rolls after it.
#
# Kept in a module so tests can replace it whole (override_module): local-exec
# provisioners run even for an overridden resource, and these call AWS.

locals {
  scripts_dir = "${path.module}/../../../deploy"
}

resource "terraform_data" "upload_config" {
  triggers_replace = [var.config_bucket_name, var.config_object_key]

  provisioner "local-exec" {
    command = "${local.scripts_dir}/put-config.sh"
    environment = {
      CONFIG_BUCKET  = var.config_bucket_name
      CONFIG_KEY     = var.config_object_key
      CONFIG_CONTENT = var.config_content
      AWS_REGION     = var.region
    }
  }
}

resource "terraform_data" "migrate" {
  triggers_replace = [var.migrate_task_definition_revision, var.image]

  provisioner "local-exec" {
    command = "${local.scripts_dir}/run-migration.sh"
    environment = {
      CLUSTER         = var.cluster_name
      TASK_DEFINITION = var.migrate_task_definition_arn
      SUBNETS         = join(",", var.subnet_ids)
      SECURITY_GROUPS = join(",", var.security_group_ids)
      AWS_REGION      = var.region
    }
  }

  # The migration task loads the config at start.
  depends_on = [terraform_data.upload_config]
}
