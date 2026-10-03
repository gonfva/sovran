locals {
  ecr_repos = {
    netcheck = {
      name      = "${local.name_prefix}/netcheck"
      component = "platform"
      keep      = 5
    }
    agent = {
      name      = "${local.name_prefix}/agent"
      component = "agent"
      keep      = 10
    }
    sync = {
      name      = "${local.name_prefix}/sync"
      component = "agent"
      keep      = 10
    }
  }
}


# The map stays defined in both modes — locals.repository_urls uses its keys and .name to
# build S3 registry paths, so the repo *names* survive registry_mode = "s3" even though no
# ECR repository does. That keeps "sovran/agent" meaning the same thing in either registry.
resource "aws_ecr_repository" "this" {
  for_each = local.registry_s3 ? {} : local.ecr_repos

  name                 = each.value.name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = merge(local.base_tags, {
    Name      = replace(each.value.name, "/", "-")
    Component = each.value.component
  })
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = local.registry_s3 ? {} : local.ecr_repos

  repository = aws_ecr_repository.this[each.key].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last ${each.value.keep} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = each.value.keep
        }
        action = { type = "expire" }
      }
    ]
  })
}
