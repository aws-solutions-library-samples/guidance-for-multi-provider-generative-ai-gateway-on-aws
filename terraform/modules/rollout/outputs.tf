output "migration_id" {
  description = "Changes whenever the migration re-ran; the service depends on the module, so it rolls only after a successful migration."
  value       = terraform_data.migrate.id
}
