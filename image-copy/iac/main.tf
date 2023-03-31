terraform {
  required_providers {
    ko = {
      source = "ko-build/ko"
    }
    google = {
      source = "hashicorp/google"
    }
    chainguard = {
      source = "chainguard/chainguard"
    }
  }
}

provider "google" {
  project = var.project_id
}

resource "google_service_account" "image-copy" {
  account_id = "${var.name}-image-copy"
}

resource "ko_build" "image" {
  importpath  = "github.com/imjasonh/terraform-playground/image-copy/cmd/app"
  working_dir = path.module
}

resource "google_cloud_run_service" "image-copy" {
  name     = "${var.name}-image-copy"
  location = var.location

  template {
    spec {
      service_account_name = google_service_account.image-copy.email
      containers {
        image = ko_build.image.image_ref
        env {
          name  = "ISSUER_URL"
          value = "https://issuer.${var.env}"
        }
        env {
          name  = "GROUP"
          value = var.group
        }
        env {
          name  = "IDENTITY"
          value = chainguard_identity.puller-identity.id
        }
        env {
          name  = "DST_REPO"
          value = "${var.location}-docker.pkg.dev/${var.project_id}/${var.dst_repo}"
        }
      }
    }
  }
}

data "google_iam_policy" "noauth" {
  binding {
    role = "roles/run.invoker"
    members = [
      "allUsers",
    ]
  }
}

resource "google_cloud_run_service_iam_policy" "noauth" {
  location = google_cloud_run_service.image-copy.location
  service  = google_cloud_run_service.image-copy.name

  policy_data = data.google_iam_policy.noauth.policy_data
}

resource "google_artifact_registry_repository" "dst-repo" {
  location      = var.location
  repository_id = var.dst_repo
  description   = "image-copy repository"
  format        = "DOCKER"
}

resource "google_artifact_registry_repository_iam_member" "member" {
  location   = google_artifact_registry_repository.dst-repo.location
  repository = google_artifact_registry_repository.dst-repo.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.image-copy.email}"
}

# Create the identity for our Cloud Run service to assume.
resource "chainguard_identity" "puller-identity" {
  parent_id = var.group
  name      = "image-copy cgr puller"

  claim_match {
    issuer  = "https://accounts.google.com"
    subject = google_service_account.image-copy.unique_id
  }
}

# Look up the registry.pull role to grant the identity.
data "chainguard_roles" "puller" {
  name = "registry.pull"
}

# Grant the identity the "registry.pull" role on the root group.
resource "chainguard_rolebinding" "puller" {
  identity = chainguard_identity.puller-identity.id
  group    = var.group
  role     = data.chainguard_roles.puller.items[0].id
}

# Create a subscription to notify the Cloud Run service on changes under the root group.
resource "chainguard_subscription" "subscription" {
  parent_id = var.group
  sink      = google_cloud_run_service.image-copy.status[0].url
}
