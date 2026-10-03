# Preserve existing Phase 1 ECR resources after for_each refactor.
moved {
  from = aws_ecr_repository.netcheck
  to   = aws_ecr_repository.this["netcheck"]
}

moved {
  from = aws_ecr_lifecycle_policy.netcheck
  to   = aws_ecr_lifecycle_policy.this["netcheck"]
}

