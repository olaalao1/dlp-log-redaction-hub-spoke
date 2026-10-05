variable "hub_project_id" {
  description = "Google Cloud Hub Project ID where Pub/Sub, DLP Templates, and Cloud Run Redactor reside"
  type        = string
  default     = "vertex-security-4f90bf"
}

variable "spoke_project_id" {
  description = "Google Cloud Spoke Project ID where agents (spotify-3lo-agent) and _Default log bucket reside"
  type        = string
  default     = "gemini-cyber"
}

variable "region" {
  description = "GCP Region for Cloud Run, Eventarc, and Pub/Sub"
  type        = string
  default     = "us-central1"
}

variable "focal_agent_display_name" {
  description = "Display name of the focal agent in the spoke project"
  type        = string
  default     = "spotify-3lo-agent"
}

variable "focal_agent_reasoning_engine_id" {
  description = "Reasoning Engine ID of the focal agent in the spoke project"
  type        = string
  default     = "5018221096948727808"
}
