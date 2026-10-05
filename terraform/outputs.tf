output "hub_project" {
  description = "Hub project ID and project number"
  value = {
    project_id     = data.google_project.hub.project_id
    project_number = data.google_project.hub.number
  }
}

output "spoke_project" {
  description = "Spoke project ID, project number, and focal agent details"
  value = {
    project_id                      = data.google_project.spoke.project_id
    project_number                  = data.google_project.spoke.number
    focal_agent_display_name        = var.focal_agent_display_name
    focal_agent_reasoning_engine_id = var.focal_agent_reasoning_engine_id
  }
}

output "pubsub_topic" {
  description = "Hub Pub/Sub ingestion topic ID"
  value       = google_pubsub_topic.agent_logs_topic.id
}

output "spoke_logging_sink" {
  description = "Spoke Cloud Logging export sink details"
  value = {
    name            = google_logging_project_sink.dlp_export_sink.name
    destination     = google_logging_project_sink.dlp_export_sink.destination
    writer_identity = google_logging_project_sink.dlp_export_sink.writer_identity
    exclusion_name  = google_logging_project_exclusion.exclude_unredacted_logs.name
  }
}

output "dlp_templates" {
  description = "Cloud DLP inspect and de-identify template resource names in Hub"
  value = {
    inspect_template    = google_data_loss_prevention_inspect_template.agent_inspect_template.id
    deidentify_template = google_data_loss_prevention_deidentify_template.agent_deidentify_template.id
  }
}

output "cloud_run_redactor" {
  description = "Cloud Run / 2nd Gen Cloud Function auto-redactor details in Hub"
  value = {
    name                  = google_cloudfunctions2_function.auto_redactor.name
    url                   = google_cloudfunctions2_function.auto_redactor.url
    service_account_email = google_service_account.redactor_sa.email
  }
}
