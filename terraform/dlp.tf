resource "google_data_loss_prevention_inspect_template" "agent_inspect_template" {
  parent       = "projects/${var.hub_project_id}/locations/global"
  template_id  = "agent-logs-inspect-template"
  display_name = "Agent Telemetry Inspection Template"

  inspect_config {
    min_likelihood = "POSSIBLE"
    limits {
      max_findings_per_item    = 0
      max_findings_per_request = 0
    }

    info_types { name = "EMAIL_ADDRESS" }
    info_types { name = "PHONE_NUMBER" }
    info_types { name = "PERSON_NAME" }
    info_types { name = "CREDIT_CARD_NUMBER" }
    info_types { name = "US_SOCIAL_SECURITY_NUMBER" }
    info_types { name = "IP_ADDRESS" }
    info_types { name = "STREET_ADDRESS" }
    info_types { name = "GEMINI_API_KEY" }
    info_types { name = "OPENAI_API_KEY" }
    info_types { name = "ANTHROPIC_API_KEY" }
    info_types { name = "GCP_API_KEY" }
    info_types { name = "GCP_CREDENTIALS" }
    info_types { name = "AWS_CREDENTIALS" }
    info_types { name = "JSON_WEB_TOKEN" }
    info_types { name = "OAUTH_CLIENT_SECRET" }
    info_types { name = "AUTH_TOKEN" }
    info_types { name = "BASIC_AUTH_HEADER" }
    info_types { name = "HTTP_COOKIE" }
    info_types { name = "ENCRYPTION_KEY" }

    custom_info_types {
      info_type { name = "GENERIC_BEARER_TOKEN" }
      regex { pattern = "Bearer [A-Za-z0-9\\-\\._~\\+\\/]+=*" }
      likelihood = "LIKELY"
    }

    custom_info_types {
      info_type { name = "GCP_API_KEY_EXTENDED" }
      regex { pattern = "AIza[0-9A-Za-z-_]{10,}" }
      likelihood = "LIKELY"
    }
  }

  depends_on = [google_project_service.hub_apis]
}

resource "google_data_loss_prevention_deidentify_template" "agent_deidentify_template" {
  parent       = "projects/${var.hub_project_id}/locations/global"
  template_id  = "agent-logs-redaction-template"
  display_name = "Agent Telemetry Redaction Template"

  deidentify_config {
    info_type_transformations {
      transformations {
        primitive_transformation {
          replace_with_info_type_config = true
        }
      }
    }
  }

  depends_on = [google_project_service.hub_apis]
}
