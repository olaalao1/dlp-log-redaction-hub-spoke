import base64
import copy
import json
import logging
import os
import urllib.parse
import functions_framework
import google.cloud.dlp_v2 as dlp
from google.cloud import logging as gcp_logging

logging.basicConfig(level=logging.INFO)

PROJECT_ID = os.environ.get("GCP_PROJECT", "vertex-security-4f90bf")
SOURCE_PROJECT = os.environ.get("SOURCE_PROJECT", "gemini-cyber")
INSPECT_TEMPLATE = os.environ.get(
    "INSPECT_TEMPLATE",
    f"projects/{PROJECT_ID}/locations/global/inspectTemplates/agent-logs-inspect-template",
)
DEIDENTIFY_TEMPLATE = os.environ.get(
    "DEIDENTIFY_TEMPLATE",
    f"projects/{PROJECT_ID}/locations/global/deidentifyTemplates/agent-logs-redaction-template",
)

dlp_client = dlp.DlpServiceClient()
spoke_logging_client = gcp_logging.Client(project=SOURCE_PROJECT)
hub_logging_client = (
    gcp_logging.Client(project=PROJECT_ID)
    if PROJECT_ID != SOURCE_PROJECT
    else None
)


def redact_string(content_str: str) -> str:
    """Invokes Cloud DLP API to sanitize text and JSON strings."""
    if not content_str:
        return content_str
    try:
        response = dlp_client.deidentify_content(
            request={
                "parent": f"projects/{PROJECT_ID}/locations/global",
                "inspect_template_name": INSPECT_TEMPLATE,
                "deidentify_template_name": DEIDENTIFY_TEMPLATE,
                "item": {"value": content_str},
            }
        )
        return response.item.value
    except Exception as e:
        logging.error("DLP De-identification error: %s", e)
        return content_str


def _write_sanitized_entry(
    client: gcp_logging.Client,
    target_project: str,
    log_id: str,
    redacted_json_obj,
    redacted_text,
    sanitized_labels: dict,
    severity: str,
    raw_resource,
):
    """Writes a sanitized log entry to the given project's Cloud Logging _Default bucket."""
    resource = copy.deepcopy(raw_resource) if isinstance(raw_resource, dict) else raw_resource
    if isinstance(resource, dict) and isinstance(resource.get("labels"), dict):
        if "project_id" in resource["labels"]:
            resource["labels"]["project_id"] = target_project

    logger = client.logger(log_id)
    if redacted_json_obj is not None:
        logger.log_struct(
            info=redacted_json_obj,
            labels=sanitized_labels,
            severity=severity,
            resource=resource,
        )
    elif redacted_text is not None:
        logger.log_text(
            text=redacted_text,
            labels=sanitized_labels,
            severity=severity,
            resource=resource,
        )
    else:
        # Telemetry/metadata-only turn (where prompt is in labels)
        logger.log_struct(
            info={
                "event": sanitized_labels.get(
                    "event.name", "gen_ai.client.inference.operation.details"
                )
            },
            labels=sanitized_labels,
            severity=severity,
            resource=resource,
        )


@functions_framework.cloud_event
def process_agent_log(cloud_event):
    """Triggered by Pub/Sub to redact incoming log and write to both Spoke and Hub _Default buckets."""
    pubsub_message = cloud_event.data.get("message", {})
    data_encoded = pubsub_message.get("data")
    if not data_encoded:
        return

    raw_str = base64.b64decode(data_encoded).decode("utf-8")
    log_entry = json.loads(raw_str)

    # 1. Redact Payloads (JSON, text, proto)
    json_payload = log_entry.get("jsonPayload")
    text_payload = log_entry.get("textPayload")
    proto_payload = log_entry.get("protoPayload")
    raw_labels = log_entry.get("labels")

    redacted_text = None
    redacted_json_obj = None
    redacted_labels_obj = None

    if json_payload is not None:
        redacted_str = redact_string(json.dumps(json_payload))
        try:
            redacted_json_obj = json.loads(redacted_str)
        except Exception:
            redacted_json_obj = {"raw": redacted_str}
    elif text_payload is not None:
        redacted_text = redact_string(str(text_payload))
    elif proto_payload is not None:
        redacted_str = redact_string(json.dumps(proto_payload))
        try:
            redacted_json_obj = json.loads(redacted_str)
        except Exception:
            redacted_json_obj = {"raw_proto": redacted_str}

    # 2. Redact Labels map (agent prompts, reasoning steps, tool outputs)
    if raw_labels is not None:
        redacted_labels_raw = redact_string(json.dumps(raw_labels))
        try:
            redacted_labels_obj = json.loads(redacted_labels_raw)
        except Exception:
            redacted_labels_obj = raw_labels

    # 3. Write sanitized log to both Spoke (gemini-cyber) and Hub (vertex-security-4f90bf)
    sanitized_labels = redacted_labels_obj or {}
    if isinstance(sanitized_labels, dict):
        sanitized_labels["redacted"] = "true"
        sanitized_labels["source_project"] = SOURCE_PROJECT
    else:
        sanitized_labels = {"redacted": "true", "source_project": SOURCE_PROJECT}

    raw_log_name = log_entry.get("logName", "agent_redacted_logs")
    if "logs/" in raw_log_name:
        log_id_raw = raw_log_name.split("logs/", 1)[1]
    else:
        log_id_raw = raw_log_name.split("/")[-1]

    log_id_clean = urllib.parse.unquote(log_id_raw)
    log_id = urllib.parse.quote(log_id_clean, safe="")
    severity = log_entry.get("severity", "INFO")
    raw_resource = log_entry.get("resource")

    # Write back to Spoke project (_Default bucket)
    try:
        _write_sanitized_entry(
            client=spoke_logging_client,
            target_project=SOURCE_PROJECT,
            log_id=log_id,
            redacted_json_obj=redacted_json_obj,
            redacted_text=redacted_text,
            sanitized_labels=sanitized_labels,
            severity=severity,
            raw_resource=raw_resource,
        )
    except Exception as write_err:
        logging.warning("Failed to write sanitized log back to Spoke (%s): %s", SOURCE_PROJECT, write_err)

    # Also write to Hub project (_Default bucket)
    if hub_logging_client is not None:
        try:
            _write_sanitized_entry(
                client=hub_logging_client,
                target_project=PROJECT_ID,
                log_id=log_id,
                redacted_json_obj=redacted_json_obj,
                redacted_text=redacted_text,
                sanitized_labels=sanitized_labels,
                severity=severity,
                raw_resource=raw_resource,
            )
        except Exception as hub_err:
            logging.warning("Failed to write sanitized log to Hub (%s): %s", PROJECT_ID, hub_err)
