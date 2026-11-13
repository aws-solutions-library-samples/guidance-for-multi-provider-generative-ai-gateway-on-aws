# Plan-only: a plan never runs provisioners, so nothing here calls AWS.

variables {
  config_bucket_name               = "llmgw-config-111111111111-eu-west-1"
  config_object_key                = "config-0123456789abcdef.yaml"
  config_content                   = "model_list: []\n"
  region                           = "eu-west-1"
  cluster_name                     = "llmgw-cluster"
  migrate_task_definition_arn      = "arn:aws:ecs:eu-west-1:111111111111:task-definition/llmgw-migrate:3"
  migrate_task_definition_revision = 3
  image                            = "ghcr.io/berriai/litellm:v1.106.6@sha256:37e2dafb088a7723beb998590682957386dfc83ffea1848486f8e0e5cfac0b06"
  subnet_ids                       = ["subnet-a", "subnet-b"]
  security_group_ids               = ["sg-a", "sg-b"]
}

run "upload_runs_once_per_config_key" {
  command = plan

  assert {
    condition     = terraform_data.upload_config.triggers_replace == ["llmgw-config-111111111111-eu-west-1", "config-0123456789abcdef.yaml"]
    error_message = "The config upload must re-run exactly when the bucket or the content-addressed key changes."
  }
}

run "migration_reruns_on_new_revision_or_image" {
  command = plan

  assert {
    condition     = terraform_data.migrate.triggers_replace == [3, var.image]
    error_message = "The migration must re-run for every new migration task revision and every new image."
  }
}
