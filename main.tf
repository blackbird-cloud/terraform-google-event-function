locals {
  logging = var.log_bucket == null ? [] : [
    {
      log_bucket        = var.log_bucket
      log_object_prefix = var.log_object_prefix
    }
  ]
}

resource "null_resource" "dependent_files" {
  triggers = {
    for file in var.source_dependent_files :
    pathexpand(file.filename) => file.id
  }
}

data "null_data_source" "wait_for_files" {
  inputs = {
    # This ensures that this data resource will not be evaluated until
    # after the null_resource has been created.
    dependent_files_id = null_resource.dependent_files.id

    # This value gives us something to implicitly depend on
    # in the archive_file below.
    source_dir = pathexpand(var.source_directory)
  }
}

data "archive_file" "main" {
  type        = "zip"
  output_path = pathexpand("${var.source_directory}.zip")
  source_dir  = data.null_data_source.wait_for_files.outputs["source_dir"]
  excludes    = var.files_to_exclude_in_source_dir
}

resource "google_storage_bucket" "main" {
  count                       = var.create_bucket ? 1 : 0
  name                        = coalesce(var.bucket_name, var.name)
  force_destroy               = var.bucket_force_destroy
  location                    = var.region
  project                     = var.project_id
  storage_class               = "REGIONAL"
  labels                      = var.bucket_labels
  uniform_bucket_level_access = true

  dynamic "logging" {
    for_each = local.logging == [] ? [] : local.logging
    content {
      log_bucket        = logging.value.log_bucket
      log_object_prefix = logging.value.log_object_prefix
    }
  }

}

resource "google_storage_bucket_object" "main" {
  name                = "${data.archive_file.main.output_md5}-${basename(data.archive_file.main.output_path)}"
  bucket              = var.create_bucket ? google_storage_bucket.main[0].name : var.bucket_name
  source              = data.archive_file.main.output_path
  content_disposition = "attachment"
  content_encoding    = "zip"
  content_type        = "application/zip"
}

// todo(bharathkkb): remove workaround after https://github.com/hashicorp/terraform-provider-google/issues/11383
// Also: https://github.com/hashicorp/terraform/issues/28925 (when this functions project is created)
data "google_project" "nums" {
  for_each   = toset(compact([for item in var.secret_environment_variables : lookup(item, "project_id", "")]))
  project_id = each.value
}

data "google_project" "default" {
  project_id = var.project_id
}

resource "google_cloudfunctions2_function" "main" {
  name        = var.name
  location    = var.location
  description = var.description
  labels      = var.labels
  project     = var.project_id

  build_config {
    runtime               = var.runtime
    entry_point           = var.entry_point
    environment_variables = var.build_environment_variables
    source {
      storage_source {
        bucket = var.create_bucket ? google_storage_bucket.main[0].name : var.bucket_name
        object = google_storage_bucket_object.main.name
      }
    }
  }

  service_config {
    max_instance_count               = var.max_instance_count
    min_instance_count               = var.min_instance_count
    available_memory                 = var.available_memory
    timeout_seconds                  = var.timeout_s
    max_instance_request_concurrency = var.max_instance_request_concurrency
    available_cpu                    = var.available_cpu
    environment_variables            = var.environment_variables
    ingress_settings                 = var.ingress_settings
    vpc_connector_egress_settings    = var.vpc_connector_egress_settings
    vpc_connector                    = var.vpc_connector
    all_traffic_on_latest_revision   = var.all_traffic_on_latest_revision
    service_account_email            = var.service_account_email
    dynamic "secret_environment_variables" {
      for_each = { for item in var.secret_environment_variables : item.key => item }

      content {
        key        = secret_environment_variables.value["key"]
        project_id = try(data.google_project.nums[secret_environment_variables.value["project_id"]].number, data.google_project.default.number)
        secret     = secret_environment_variables.value["secret_name"]
        version    = lookup(secret_environment_variables.value, "version", "latest")
      }
    }

  }
}

resource "google_eventarc_trigger" "trigger" {
  name            = var.name
  location        = var.event_trigger["trigger_region"]
  service_account = "${data.google_project.default.number}-compute@developer.gserviceaccount.com"
  project         = var.project_id
  transport {
    pubsub {
      topic = var.event_trigger["pubsub_topic"]
    }
  }

  matching_criteria {
    attribute = "type"
    value     = var.event_trigger["event_type"]

  }
  destination {
    cloud_run_service {
      region  = var.region
      service = google_cloudfunctions2_function.main.name
    }
  }
}

locals {
  subscription_id = google_eventarc_trigger.trigger.transport[0].pubsub[0].subscription
}

module "dlq" {
  source  = "terraform-google-modules/gcloud/google"
  version = "3.1.2"

  platform              = "linux"
  additional_components = []

  create_cmd_entrypoint = "gcloud"
  create_cmd_body       = "pubsub subscriptions update ${local.subscription_id} --project=${var.project_id} --dead-letter-topic-project=${var.event_trigger["dlq_project_id"]} --dead-letter-topic=${var.event_trigger["dlq_topic_id"]}"
}

locals {
  default_ack_deadline_seconds = 10
  pubsub_svc_account_email     = "service-${data.google_project.default.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_subscription_iam_member" "subscription_binding" {
  project      = var.project_id
  subscription = local.subscription_id
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${local.pubsub_svc_account_email}"
}

resource "google_pubsub_topic_iam_member" "topic_binding" {
  project = var.project_id
  topic   = var.event_trigger["dlq_topic_id"]
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${local.pubsub_svc_account_email}"
}
