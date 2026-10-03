#!/usr/bin/env bash
# Full PoC teardown: stop GPU builders, scale ASG to 0, destroy TF (clients → reference).
# Usage:
#   ./scripts/teardown-all.sh
set -euo pipefail

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-west-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> stop local packer (if any)"
# kill by path only to avoid matching this script
for pid in $(ps -eo pid=,cmd= | awk '/\/usr\/bin\/packer |packer-plugin-amazon|tee \/tmp\/packer-bake/ {print $1}'); do
  kill -TERM "$pid" 2>/dev/null || true
done
sleep 2
for pid in $(ps -eo pid=,cmd= | awk '/\/usr\/bin\/packer |packer-plugin-amazon|tee \/tmp\/packer-bake/ {print $1}'); do
  kill -KILL "$pid" 2>/dev/null || true
done

echo "==> reference account: terminate G instances + ASG=0"
export AWS_PROFILE="${AWS_PROFILE_REF:-sovran-ref}"
GIDS=$(aws ec2 describe-instances \
  --filters "Name=instance-type,Values=g4dn.*,g5.*,g6.*" \
            "Name=instance-state-name,Values=pending,running,stopping" \
  --query 'Reservations[].Instances[].InstanceId' --output text || true)
if [[ -n "${GIDS:-}" && "$GIDS" != "None" ]]; then
  echo "terminating: $GIDS"
  aws ec2 terminate-instances --instance-ids $GIDS
fi

for asg in $(aws autoscaling describe-auto-scaling-groups \
  --query 'AutoScalingGroups[?contains(AutoScalingGroupName, `sovran`) || contains(AutoScalingGroupName, `model`)].AutoScalingGroupName' \
  --output text); do
  echo "ASG $asg -> desired 0"
  aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "$asg" --min-size 0 --desired-capacity 0 || true
done

echo "==> terraform destroy client-b"
cd "$ROOT/infra/envs/client-b"
terraform destroy -auto-approve

echo "==> terraform destroy client-a"
cd "$ROOT/infra/envs/client-a"
terraform destroy -auto-approve

echo "==> terraform destroy reference"
cd "$ROOT/infra/envs/reference"
terraform destroy -auto-approve

echo "==> teardown complete"
export AWS_PROFILE=sovran-ref
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=pending,running" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,Tags[?Key==`Name`].Value|[0]]' \
  --output table || true
