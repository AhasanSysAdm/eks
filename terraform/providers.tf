provider "aws" {
  region = var.region

  # Every taggable resource gets env=test-eks for Cost Explorer.
  default_tags {
    tags = {
      (var.cost_tag_key) = var.cost_tag_value
      Project            = var.cluster_name
      Purpose            = "classroom-only"
    }
  }
}
