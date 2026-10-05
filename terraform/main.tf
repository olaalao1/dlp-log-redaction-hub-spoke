terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.20.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 5.20.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4.0"
    }
  }
}

provider "google" {
  project               = var.hub_project_id
  region                = var.region
  user_project_override = true
  billing_project       = var.hub_project_id
}

provider "google-beta" {
  project               = var.hub_project_id
  region                = var.region
  user_project_override = true
  billing_project       = var.hub_project_id
}

data "google_project" "hub" {
  project_id = var.hub_project_id
}

data "google_project" "spoke" {
  project_id = var.spoke_project_id
}

locals {
  aiplatform_unredacted_filter = "NOT labels.redacted=\"true\" AND (resource.type =~ \"aiplatform.googleapis.com/.*\" OR logName =~ \"logs/aiplatform.googleapis.com.*\" OR protoPayload.serviceName = \"aiplatform.googleapis.com\")"

  hub_services = [
    "pubsub.googleapis.com",
    "dlp.googleapis.com",
    "cloudfunctions.googleapis.com",
    "run.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "eventarc.googleapis.com",
    "logging.googleapis.com",
    "storage.googleapis.com",
  ]
}

# -------------------------------------------------------------------------
# Enable Required APIs in Hub and Spoke Projects
# -------------------------------------------------------------------------
resource "google_project_service" "hub_apis" {
  for_each           = toset(local.hub_services)
  project            = var.hub_project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_project_service" "spoke_logging_api" {
  project            = var.spoke_project_id
  service            = "logging.googleapis.com"
  disable_on_destroy = false
}

# Ensure Google-managed service agents exist in the Hub project
resource "google_project_service_identity" "pubsub_sa" {
  provider   = google-beta
  project    = data.google_project.hub.project_id
  service    = "pubsub.googleapis.com"
  depends_on = [google_project_service.hub_apis]
}

resource "google_project_service_identity" "eventarc_sa" {
  provider   = google-beta
  project    = data.google_project.hub.project_id
  service    = "eventarc.googleapis.com"
  depends_on = [google_project_service.hub_apis]
}

resource "google_project_service_identity" "dlp_sa" {
  provider   = google-beta
  project    = data.google_project.hub.project_id
  service    = "dlp.googleapis.com"
  depends_on = [google_project_service.hub_apis]
}

# -------------------------------------------------------------------------
# Hub Project: Pub/Sub Ingestion Topic & Buffer Subscription
# -------------------------------------------------------------------------
resource "google_pubsub_topic" "agent_logs_topic" {
  project    = var.hub_project_id
  name       = "governance-agent-logs"
  depends_on = [google_project_service.hub_apis]
}

resource "google_pubsub_subscription" "agent_logs_sub" {
  project                    = var.hub_project_id
  name                       = "governance-agent-logs-sub"
  topic                      = google_pubsub_topic.agent_logs_topic.id
  message_retention_duration = "604800s" # 7 Days Buffer
  ack_deadline_seconds       = 60
}

# -------------------------------------------------------------------------
# Spoke Project (gemini-cyber): Cloud Logging Exclusion on _Default Bucket
# -------------------------------------------------------------------------
resource "google_logging_project_exclusion" "exclude_unredacted_logs" {
  project     = var.spoke_project_id
  name        = "exclude-all-unredacted-logs-ai"
  description = "Blocks raw AI Platform logs from entering _Default unless tagged as redacted"
  filter      = local.aiplatform_unredacted_filter
  depends_on  = [google_project_service.spoke_logging_api]
}

# -------------------------------------------------------------------------
# Spoke Project (gemini-cyber): Export Log Sink -> Hub Pub/Sub Topic
# -------------------------------------------------------------------------
resource "google_logging_project_sink" "dlp_export_sink" {
  project                = var.spoke_project_id
  name                   = "governance-dlp-sink"
  destination            = "pubsub.googleapis.com/projects/${var.hub_project_id}/topics/${google_pubsub_topic.agent_logs_topic.name}"
  filter                 = local.aiplatform_unredacted_filter
  unique_writer_identity = true
  depends_on             = [google_project_service.spoke_logging_api]
}

# Grant Publisher permissions on Hub Topic to Spoke Log Sink's writer identity
resource "google_pubsub_topic_iam_member" "sink_pubsub_publisher" {
  project = var.hub_project_id
  topic   = google_pubsub_topic.agent_logs_topic.name
  role    = "roles/pubsub.publisher"
  member  = google_logging_project_sink.dlp_export_sink.writer_identity
}

# -------------------------------------------------------------------------
# Hub Worker Service Account & Cross-Project IAM Permissions
# -------------------------------------------------------------------------
resource "google_service_account" "redactor_sa" {
  project      = var.hub_project_id
  account_id   = "dlp-redactor-sa"
  display_name = "Agent Log DLP Redactor Service Account (Hub)"
}

# Allow Hub worker SA to write sanitized logs back to Spoke Cloud Logging (_Default bucket)
resource "google_project_iam_member" "worker_spoke_log_writer" {
  project = var.spoke_project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.redactor_sa.email}"
}

# Allow Hub worker SA to write its own function logs in Hub
resource "google_project_iam_member" "worker_hub_log_writer" {
  project = var.hub_project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.redactor_sa.email}"
}

# Allow Hub worker SA to invoke Cloud DLP API in Hub
resource "google_project_iam_member" "worker_dlp_user" {
  project = var.hub_project_id
  role    = "roles/dlp.user"
  member  = "serviceAccount:${google_service_account.redactor_sa.email}"
}

resource "google_project_iam_member" "worker_dlp_admin" {
  project = var.hub_project_id
  role    = "roles/dlp.admin"
  member  = "serviceAccount:${google_service_account.redactor_sa.email}"
}

# Allow Hub worker SA to subscribe to and view Pub/Sub in Hub
resource "google_project_iam_member" "worker_pubsub_subscriber" {
  project = var.hub_project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.redactor_sa.email}"
}

resource "google_project_iam_member" "worker_pubsub_viewer" {
  project = var.hub_project_id
  role    = "roles/pubsub.viewer"
  member  = "serviceAccount:${google_service_account.redactor_sa.email}"
}

# Allow Hub Pub/Sub Service Agent to mint OIDC tokens for dlp-redactor-sa
resource "google_project_iam_member" "pubsub_token_creator" {
  project    = var.hub_project_id
  role       = "roles/iam.serviceAccountTokenCreator"
  member     = "serviceAccount:service-${data.google_project.hub.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
  depends_on = [google_project_service_identity.pubsub_sa]
}

resource "google_project_iam_member" "pubsub_service_agent" {
  project    = var.hub_project_id
  role       = "roles/pubsub.serviceAgent"
  member     = "serviceAccount:service-${data.google_project.hub.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
  depends_on = [google_project_service_identity.pubsub_sa]
}

# Allow Hub Eventarc Service Agent to manage triggers
resource "google_project_iam_member" "eventarc_service_agent" {
  project    = var.hub_project_id
  role       = "roles/eventarc.serviceAgent"
  member     = "serviceAccount:service-${data.google_project.hub.number}@gcp-sa-eventarc.iam.gserviceaccount.com"
  depends_on = [google_project_service_identity.eventarc_sa]
}

# Allow Hub DLP Service Agent to execute templates
resource "google_project_iam_member" "dlp_service_agent" {
  project    = var.hub_project_id
  role       = "roles/dlp.serviceAgent"
  member     = "serviceAccount:service-${data.google_project.hub.number}@dlp-api.iam.gserviceaccount.com"
  depends_on = [google_project_service_identity.dlp_sa]
}

resource "google_project_iam_member" "dlp_project_driver" {
  project    = var.hub_project_id
  role       = "roles/dlp.projectdriver"
  member     = "serviceAccount:service-${data.google_project.hub.number}@dlp-api.iam.gserviceaccount.com"
  depends_on = [google_project_service_identity.dlp_sa]
}

# Allow Cloud Functions 2nd Gen / Cloud Build service accounts to fetch source and push images
resource "google_project_iam_member" "compute_sa_builder" {
  for_each = toset([
    "roles/cloudbuild.builds.builder",
    "roles/storage.objectAdmin",
    "roles/artifactregistry.writer",
    "roles/logging.logWriter",
  ])
  project = var.hub_project_id
  role    = each.value
  member  = "serviceAccount:${data.google_project.hub.number}-compute@developer.gserviceaccount.com"
}

resource "google_project_iam_member" "redactor_sa_builder" {
  for_each = toset([
    "roles/cloudbuild.builds.builder",
    "roles/storage.objectAdmin",
    "roles/artifactregistry.writer",
  ])
  project = var.hub_project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.redactor_sa.email}"
}
