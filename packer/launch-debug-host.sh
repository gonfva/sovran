#!/usr/bin/env bash
# Launch a public On-Demand GPU host from Amazon Deep Learning AMI for SSH + journal debug.
# Default: g5.xlarge (24GB A10G) — matches vLLM Gemma4 E2B "24GB+" guidance and 4 vCPU G quota.
# Does NOT use older Sovran AMIs — always start from Amazon DLAMI and install current vLLM.
#
# Usage:
#   export AWS_PROFILE=sovran-ref AWS_DEFAULT_REGION=eu-west-1
#   ./packer/launch-debug-host.sh              # latest DLAMI + g5.xlarge
#   INSTANCE_TYPE=g6.xlarge ./packer/launch-debug-host.sh
#   ./packer/launch-debug-host.sh ami-xxxxxxxx # explicit Amazon AMI only
#
set -euo pipefail

KEY_NAME="${KEY_NAME:-sovran-packer-debug}"
KEY_FILE="${KEY_FILE:-$HOME/.ssh/${KEY_NAME}.pem}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g5.xlarge}"
NAME_TAG="${NAME_TAG:-sovran-model-debug}"
ROOT_GB="${ROOT_GB:-100}"

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-west-1}"

if ! aws sts get-caller-identity >/dev/null; then
  echo "ERROR: AWS credentials not working (profile=${AWS_PROFILE:-default})" >&2
  exit 1
fi

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
echo "==> account=$ACCOUNT region=$AWS_DEFAULT_REGION"

# Resolve AMI: arg, or latest Amazon DLAMI (never default to old Sovran bake)
if [[ -n "${1:-}" ]]; then
  AMI_ID="$1"
else
  AMI_ID=$(aws ec2 describe-images --owners amazon 898082745236 \
    --filters \
      "Name=name,Values=Deep Learning Base OSS Nvidia Driver GPU AMI (Amazon Linux 2023)*" \
      "Name=state,Values=available" \
      "Name=architecture,Values=x86_64" \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
fi
AMI_NAME=$(aws ec2 describe-images --image-ids "$AMI_ID" --query 'Images[0].Name' --output text)
echo "==> AMI=$AMI_ID ($AMI_NAME)"
if [[ "$AMI_NAME" == *sovran* ]]; then
  echo "ERROR: refusing Sovran AMI — use Amazon DLAMI as base (omit arg or pass an Amazon AMI id)." >&2
  exit 1
fi

LIVE=$(aws ec2 describe-instances \
  --filters "Name=instance-type,Values=g4dn.*,g5.*,g6.*" \
            "Name=instance-state-name,Values=pending,running" \
  --query 'length(Reservations[].Instances[])' --output text)
if [[ "$LIVE" != "0" ]]; then
  echo "ERROR: $LIVE G-family instance(s) already running (quota often 4 vCPU = 1× g5.xlarge)." >&2
  aws ec2 describe-instances \
    --filters "Name=instance-type,Values=g4dn.*,g5.*,g6.*" \
              "Name=instance-state-name,Values=pending,running" \
    --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,State:State.Name,Name:Tags[?Key==`Name`].Value|[0]}' \
    --output table
  exit 1
fi

VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)

# G capacity is per-AZ and runs out (eu-west-1a had no g5.xlarge on 2026-08-12).
# Collect every default subnet that offers this instance type and try them in turn.
if [[ -n "${SUBNET_ID:-}" ]]; then
  CANDIDATE_SUBNETS=("$SUBNET_ID")
else
  OFFERED_AZS=$(aws ec2 describe-instance-type-offerings \
    --location-type availability-zone \
    --filters "Name=instance-type,Values=$INSTANCE_TYPE" \
    --query 'InstanceTypeOfferings[].Location' --output text)
  if [[ -z "$OFFERED_AZS" ]]; then
    echo "ERROR: $INSTANCE_TYPE is not offered in any AZ of $AWS_DEFAULT_REGION." >&2
    echo "       (g6.xlarge, for example, does not exist in eu-west-1.)" >&2
    exit 1
  fi
  read -r -a CANDIDATE_SUBNETS <<<"$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=default-for-az,Values=true" \
    "Name=availability-zone,Values=$(tr '\t' ',' <<<"$OFFERED_AZS")" \
    --query 'Subnets[].SubnetId' --output text)"
fi
echo "==> default VPC=$VPC_ID candidate subnets: ${CANDIDATE_SUBNETS[*]}"

if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  echo "==> creating key pair $KEY_NAME → $KEY_FILE"
  mkdir -p "$(dirname "$KEY_FILE")"
  aws ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text >"$KEY_FILE"
  chmod 600 "$KEY_FILE"
else
  echo "==> using key pair $KEY_NAME (local: $KEY_FILE)"
fi

SG_NAME="sovran-packer-debug"
SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
if [[ -z "$SG" || "$SG" == "None" ]]; then
  SG=$(aws ec2 create-security-group --group-name "$SG_NAME" \
    --description "temp SSH for model AMI debug" --vpc-id "$VPC_ID" \
    --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$SG" \
    --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null
  echo "==> created SG $SG"
else
  echo "==> reusing SG $SG"
fi

# Spot G quota is often 0; On-Demand is the default. USE_SPOT=1 only if Spot G > 0.
MARKET_ARGS=()
if [[ "${USE_SPOT:-0}" == "1" ]]; then
  echo "==> Spot $INSTANCE_TYPE"
  MARKET_ARGS=(--instance-market-options "MarketType=spot,SpotOptions={SpotInstanceType=one-time,InstanceInterruptionBehavior=terminate}")
else
  echo "==> On-Demand $INSTANCE_TYPE"
fi

echo "==> launching from Amazon DLAMI $AMI_ID"
IID=""
for subnet in "${CANDIDATE_SUBNETS[@]}"; do
  AZ=$(aws ec2 describe-subnets --subnet-ids "$subnet" \
    --query 'Subnets[0].AvailabilityZone' --output text)
  echo "==> trying $subnet ($AZ)"
  if IID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --subnet-id "$subnet" \
    --security-group-ids "$SG" \
    --associate-public-ip-address \
    --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":${ROOT_GB},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
    "${MARKET_ARGS[@]}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME_TAG},{Key=Project,Value=sovran},{Key=Role,Value=packer-debug},{Key=BaseAmi,Value=$AMI_ID}]" \
    --query 'Instances[0].InstanceId' --output text 2>/tmp/run-instances.err); then
    SUBNET_ID="$subnet"
    echo "==> launched in $AZ"
    break
  fi
  ERR=$(cat /tmp/run-instances.err)
  IID=""
  if grep -q "InsufficientInstanceCapacity" <<<"$ERR"; then
    echo "==> no $INSTANCE_TYPE capacity in $AZ — trying next AZ"
    continue
  fi
  # Anything else (quota, auth, bad AMI) will not be fixed by another AZ.
  echo "$ERR" >&2
  exit 1
done

if [[ -z "$IID" ]]; then
  echo "ERROR: no AZ had $INSTANCE_TYPE capacity. Retry later, or set INSTANCE_TYPE/SUBNET_ID." >&2
  exit 1
fi

echo "==> instance $IID launching…"
aws ec2 wait instance-running --instance-ids "$IID"
IP=$(aws ec2 describe-instances --instance-ids "$IID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

cat <<EOF

============================================================
Debug host ready (Amazon DLAMI base — not old Sovran AMI)
  InstanceId : $IID
  Public IP  : $IP
  Base AMI   : $AMI_ID
  SSH        : ssh -i $KEY_FILE ec2-user@$IP

On the host (journal-first):
  # run packer/scripts/01..04 by hand with the env from model-ami.pkr.hcl,
  # or install manually: nightly vllm, download gemma-4-E2B-it, systemd, then:
  sudo journalctl -fu sovran-vllm
  /opt/sovran/serve.sh          # the exact command the unit runs

When done:
  aws ec2 terminate-instances --instance-ids $IID
============================================================
EOF
