data "archive_file" "function_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../function"
  output_path = "${path.module}/cloud_function.zip"
}

resource "google_storage_bucket" "function_source_bucket" {
  project                     = var.hub_project_id
  name                        = "${var.hub_project_id}-gcf-source"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
  depends_on                  = [google_project_service.hub_apis]
}

resource "google_storage_bucket_object" "function_zip" {
  name   = "agent-dlp-auto-redactor/source-${data.archive_file.function_zip.output_md5}.zip"
  bucket = google_storage_bucket.function_source_bucket.name
  source = data.archive_file.function_zip.output_path
}

resource "google_cloudfunctions2_function" "auto_redactor" {
  project     = var.hub_project_id
  name        = "agent-dlp-auto-redactor"
  location    = var.region
  description = "Real-Time Event-Driven DLP Log Redactor (Hub: ${var.hub_project_id}, Spoke: ${var.spoke_project_id})"

  build_config {
    runtime     = "python311"
    entry_point = "process_agent_log"
    source {
      storage_source {
        bucket = google_storage_bucket.function_source_bucket.name
        object = google_storage_bucket_object.function_zip.name
      }
    }
  }

  service_config {
    max_instance_count             = 100
    min_instance_count             = 0
    available_memory               = "256M"
    timeout_seconds                = 60
    service_account_email          = google_service_account.redactor_sa.email
    all_traffic_on_latest_revision = true

    environment_variables = {
      GCP_PROJECT         = var.hub_project_id
      SOURCE_PROJECT      = var.spoke_project_id
      INSPECT_TEMPLATE    = "projects/${var.hub_project_id}/locations/global/inspectTemplates/${google_data_loss_prevention_inspect_template.agent_inspect_template.template_id}"
      DEIDENTIFY_TEMPLATE = "projects/${var.hub_project_id}/locations/global/deidentifyTemplates/${google_data_loss_prevention_deidentify_template.agent_deidentify_template.template_id}"
    }
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = google_pubsub_topic.agent_logs_topic.id
    retry_policy          = "RETRY_POLICY_DO_NOT_RETRY"
    service_account_email = google_service_account.redactor_sa.email
  }

  depends_on = [
    google_project_service.hub_apis,
    google_project_iam_member.worker_spoke_log_writer,
    google_project_iam_member.worker_dlp_user,
    google_project_iam_member.worker_pubsub_subscriber,
    google_project_iam_member.pubsub_token_creator,
    google_project_iam_member.eventarc_service_agent,
    google_project_iam_member.compute_sa_builder,
    google_project_iam_member.redactor_sa_builder,
  ]
}

# Grant Cloud Run Invoker to Trigger SA, Eventarc Service Agent, and Pub/Sub Service Agent
resource "google_cloud_run_service_iam_binding" "redactor_invokers" {
  project  = google_cloudfunctions2_function.auto_redactor.project
  location = google_cloudfunctions2_function.auto_redactor.location
  service  = google_cloudfunctions2_function.auto_redactor.name
  role     = "roles/run.invoker"

  members = [
    "serviceAccount:${google_service_account.redactor_sa.email}",
    "serviceAccount:service-${data.google_project.hub.number}@gcp-sa-eventarc.iam.gserviceaccount.com",
    "serviceAccount:service-${data.google_project.hub.number}@gcp-sa-pubsub.iam.gserviceaccount.com",
  ]
}
