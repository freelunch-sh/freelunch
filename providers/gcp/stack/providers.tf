# Credentials come from Application Default Credentials: `gcloud auth application-default login`,
# or GOOGLE_APPLICATION_CREDENTIALS pointing at a service account key.
provider "google" {
  project = var.project_id
  region  = var.region
}
