#!/usr/bin/env bash

set -euo pipefail

REGION="${REGION:-eu-west-1}"
TOPIC_ARN="${TOPIC_ARN:-}"
ALARM_PREFIX="${ALARM_PREFIX:-Alert}"
OBSOLETE_DISK_ALARM_PREFIXES="${OBSOLETE_DISK_ALARM_PREFIXES:-$ALARM_PREFIX}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

require_command aws
require_command jq

if [ -z "$TOPIC_ARN" ]; then
  echo "TOPIC_ARN is required. Example:"
  echo "REGION=\"$REGION\" TOPIC_ARN=\"arn:aws:sns:$REGION:123456789012:EC2_Alerts\" bash ALARMS.sh"
  exit 1
fi

aws sts get-caller-identity --region "$REGION" >/dev/null

create_alarm() {
  local alarm_name="$1"
  local alarm_description="$2"
  local namespace="$3"
  local metric_name="$4"
  local statistic="$5"
  local period="$6"
  local evaluation_periods="$7"
  local datapoints_to_alarm="$8"
  local threshold="$9"
  local comparison_operator="${10}"
  shift 10

  aws cloudwatch put-metric-alarm \
    --region "$REGION" \
    --alarm-name "$alarm_name" \
    --alarm-description "$alarm_description" \
    --namespace "$namespace" \
    --metric-name "$metric_name" \
    --dimensions "$@" \
    --statistic "$statistic" \
    --period "$period" \
    --evaluation-periods "$evaluation_periods" \
    --datapoints-to-alarm "$datapoints_to_alarm" \
    --threshold "$threshold" \
    --comparison-operator "$comparison_operator" \
    --treat-missing-data notBreaching \
    --alarm-actions "$TOPIC_ARN"
}

metric_dimension_args() {
  jq -r '.Dimensions | sort_by(.Name)[] | "Name=\(.Name),Value=\(.Value)"'
}

metric_dimension_label() {
  jq -r '.Dimensions | sort_by(.Name) | map("\(.Name)=\(.Value)") | join(",")'
}

safe_alarm_id() {
  tr '/,= :()' '--------' | tr -cd '[:alnum:]_.-'
}

text_items() {
  tr '\t ' '\n\n' | jq -R -c 'select(length > 0)'
}

delete_obsolete_linux_disk_alarms() {
  local cleanup_prefix

  for cleanup_prefix in $OBSOLETE_DISK_ALARM_PREFIXES; do
    aws cloudwatch describe-alarms \
      --region "$REGION" \
      --alarm-name-prefix "$cleanup_prefix" \
      --query "MetricAlarms[]" \
      --output json | jq -r '
    def dim($name): (.Dimensions | map(select(.Name == $name).Value) | first) // "";
    def lower_dim($name): (dim($name) | ascii_downcase);
    def obsolete_linux_disk_alarm:
      .Namespace == "CWAgent"
      and .MetricName == "disk_used_percent"
      and (
        lower_dim("fstype") == "squashfs"
        or (lower_dim("device") | startswith("loop"))
        or (lower_dim("path") | startswith("/snap/"))
      );

    .[] |
    select(obsolete_linux_disk_alarm) |
    .AlarmName
    ' | while read -r ALARM_NAME; do
      [ -z "$ALARM_NAME" ] && continue
      echo "Deleting obsolete snap/loop disk alarm: $ALARM_NAME"
      aws cloudwatch delete-alarms \
        --region "$REGION" \
        --alarm-names "$ALARM_NAME"
    done
  done
}

preferred_instance_metric_dimensions() {
  local instance_id="$1"
  local image_id="$2"
  local instance_type="$3"

  jq -c \
    --arg instance_id "$instance_id" \
    --arg image_id "$image_id" \
    --arg instance_type "$instance_type" '
    def dim($name): (.Dimensions | map(select(.Name == $name).Value) | first) // "";
    def dimension_names: [.Dimensions[]?.Name] | sort;
    def has_current_instance_identity:
      dim("InstanceId") == $instance_id
      and dim("ImageId") == $image_id
      and dim("InstanceType") == $instance_type;

    def instance_id_only:
      [
        .[] |
        select(dimension_names == ["InstanceId"] and dim("InstanceId") == $instance_id)
      ];

    def instance_identity:
      [
        .[] |
        select(
          dimension_names == ["ImageId", "InstanceId", "InstanceType"]
          and has_current_instance_identity
        )
      ];

    def extended_instance_identity:
      [
        .[] |
        select(
          (dimension_names | index("InstanceId")) != null
          and (dimension_names | index("ImageId")) != null
          and (dimension_names | index("InstanceType")) != null
          and has_current_instance_identity
        )
      ] | sort_by(.Dimensions | length) | .[0:1];

    instance_id_only as $preferred |
    if ($preferred | length) > 0 then
      $preferred
    elif (instance_identity | length) > 0 then
      instance_identity
    else
      extended_instance_identity
    end
  '
}

cwagent_linux_disk_metrics() {
  aws cloudwatch list-metrics \
    --region "$REGION" \
    --namespace "CWAgent" \
    --metric-name "disk_used_percent" \
    --query "Metrics[]" \
    --output json | jq -c --argjson instances "$RUNNING_INSTANCES_JSON" '
    def dim($name): (.Dimensions | map(select(.Name == $name).Value) | first) // "";
    def lower_dim($name): (dim($name) | ascii_downcase);
    def dimension_names: [.Dimensions[]?.Name] | sort;
    def exact_dims($names): dimension_names == ($names | sort);
    def has_dims($names): (($names | sort) - dimension_names | length) == 0;
    def current_instance:
      . as $metric |
      [$instances[] | select(.Id == ($metric | dim("InstanceId")))] | first;
    def has_current_instance_id:
      (dim("InstanceId") == "") or (current_instance != null);
    def has_current_instance_identity:
      current_instance as $instance |
      $instance != null
      and dim("ImageId") == ($instance.ImageId // "")
      and dim("InstanceType") == ($instance.Type // "");
    def dimension_label:
      .Dimensions | sort_by(.Name) | map("\(.Name)=\(.Value)") | join(",");
    def disk_key:
      [
        dim("InstanceId"),
        dim("host"),
        dim("path"),
        dim("device"),
        dim("fstype")
      ] | join("|");
    def preference_score:
      if exact_dims(["InstanceId", "device", "fstype", "path"]) then 0
      elif exact_dims(["InstanceId", "ImageId", "InstanceType", "device", "fstype", "path"]) and has_current_instance_identity then 1
      elif has_dims(["InstanceId", "ImageId", "InstanceType", "device", "fstype", "path"]) and has_current_instance_identity then 2
      elif exact_dims(["host", "device", "fstype", "path"]) then 3
      elif has_dims(["host", "device", "fstype", "path"]) then 4
      else 9
      end;
    def excluded_fs($value):
      [
        "tmpfs", "devtmpfs", "squashfs", "overlay", "proc", "sysfs",
        "cgroup", "cgroup2", "debugfs", "devpts", "securityfs",
        "selinuxfs", "tracefs", "autofs", "mqueue", "hugetlbfs",
        "configfs", "fusectl", "ramfs"
      ] | index($value) != null;

    [
      .[] |
      lower_dim("fstype") as $fstype |
      lower_dim("device") as $device |
      lower_dim("path") as $path |
      select((excluded_fs($fstype) | not)
        and (excluded_fs($device) | not)
        and (($device | startswith("loop")) | not)
        and (($path | startswith("/snap/")) | not)
        and has_current_instance_id)
    ] |
    group_by(disk_key) |
    map(sort_by([preference_score, (.Dimensions | length), dimension_label]) | .[0])'
}

cwagent_windows_disk_metrics() {
  aws cloudwatch list-metrics \
    --region "$REGION" \
    --namespace "CWAgent" \
    --metric-name "LogicalDisk % Free Space" \
    --query "Metrics[]" \
    --output json | jq -c --argjson instances "$RUNNING_INSTANCES_JSON" '
    def dim($name): (.Dimensions | map(select(.Name == $name).Value) | first) // "";
    def lower_dim($name): (dim($name) | ascii_downcase);
    def dimension_names: [.Dimensions[]?.Name] | sort;
    def exact_dims($names): dimension_names == ($names | sort);
    def has_dims($names): (($names | sort) - dimension_names | length) == 0;
    def current_instance:
      . as $metric |
      [$instances[] | select(.Id == ($metric | dim("InstanceId")))] | first;
    def has_current_instance_id:
      (dim("InstanceId") == "") or (current_instance != null);
    def has_current_instance_identity:
      current_instance as $instance |
      $instance != null
      and dim("ImageId") == ($instance.ImageId // "")
      and dim("InstanceType") == ($instance.Type // "");
    def dimension_label:
      .Dimensions | sort_by(.Name) | map("\(.Name)=\(.Value)") | join(",");
    def disk_key:
      [
        dim("InstanceId"),
        dim("host"),
        lower_dim("instance"),
        lower_dim("objectname")
      ] | join("|");
    def preference_score:
      if exact_dims(["InstanceId", "instance", "objectname"]) then 0
      elif exact_dims(["InstanceId", "ImageId", "InstanceType", "instance", "objectname"]) and has_current_instance_identity then 1
      elif has_dims(["InstanceId", "ImageId", "InstanceType", "instance", "objectname"]) and has_current_instance_identity then 2
      elif exact_dims(["host", "instance", "objectname"]) then 3
      elif has_dims(["host", "instance", "objectname"]) then 4
      else 9
      end;

    [
      .[] |
      select(lower_dim("instance") != "_total" and has_current_instance_id)
    ] |
    group_by(disk_key) |
    map(sort_by([preference_score, (.Dimensions | length), dimension_label]) | .[0])'
}

echo "Creating CloudWatch alarms in $REGION with SNS action: $TOPIC_ARN"

echo "Discovering running EC2 instances..."
RUNNING_INSTANCES_JSON=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].{Id:InstanceId,Name:Tags[?Key=='Name']|[0].Value,Type:InstanceType,ImageId:ImageId}" \
  --output json)

while read -r ROW; do
  INSTANCE_ID=$(echo "$ROW" | jq -r '.Id')
  INSTANCE_NAME=$(echo "$ROW" | jq -r '.Name // .Id')
  INSTANCE_TYPE=$(echo "$ROW" | jq -r '.Type')
  INSTANCE_IMAGE_ID=$(echo "$ROW" | jq -r '.ImageId')
  LABEL="$INSTANCE_NAME ($INSTANCE_ID)"

  echo "Creating EC2 alarms for $LABEL"

  create_alarm "$ALARM_PREFIX-P2-$INSTANCE_ID-EC2-CPU-80" \
    "P2: CPUUtilization >= 80% for 15 minutes on $LABEL" \
    "AWS/EC2" "CPUUtilization" "Average" 300 3 3 80 "GreaterThanOrEqualToThreshold" \
    Name=InstanceId,Value="$INSTANCE_ID"

  create_alarm "$ALARM_PREFIX-P1-$INSTANCE_ID-EC2-CPU-90" \
    "P1: CPUUtilization >= 90% for 10 minutes on $LABEL" \
    "AWS/EC2" "CPUUtilization" "Maximum" 300 2 2 90 "GreaterThanOrEqualToThreshold" \
    Name=InstanceId,Value="$INSTANCE_ID"

  create_alarm "$ALARM_PREFIX-P1-$INSTANCE_ID-EC2-StatusCheckFailed" \
    "P1: EC2 status check failed for 10 minutes on $LABEL" \
    "AWS/EC2" "StatusCheckFailed" "Maximum" 300 2 2 1 "GreaterThanOrEqualToThreshold" \
    Name=InstanceId,Value="$INSTANCE_ID"

  MEMORY_METRICS=$(aws cloudwatch list-metrics \
    --region "$REGION" \
    --namespace "CWAgent" \
    --metric-name "mem_used_percent" \
    --dimensions Name=InstanceId,Value="$INSTANCE_ID" \
    --query "Metrics[]" \
    --output json | preferred_instance_metric_dimensions "$INSTANCE_ID" "$INSTANCE_IMAGE_ID" "$INSTANCE_TYPE")

  if [ "$(echo "$MEMORY_METRICS" | jq 'length')" -eq 0 ]; then
    echo "Skipping memory alarms for $INSTANCE_ID (CloudWatch Agent not installed or not reporting)."
  else
    while read -r METRIC; do
      [ -z "$METRIC" ] && continue
      mapfile -t DIMENSIONS < <(echo "$METRIC" | metric_dimension_args)
      DIMENSION_LABEL=$(echo "$METRIC" | metric_dimension_label)
      ALARM_ID=$(echo "$INSTANCE_ID-$DIMENSION_LABEL" | safe_alarm_id | cut -c1-120)

      create_alarm "$ALARM_PREFIX-P2-$ALARM_ID-EC2-Memory-85" \
        "P2: mem_used_percent >= 85% for 15 minutes on $DIMENSION_LABEL" \
        "CWAgent" "mem_used_percent" "Average" 300 3 3 85 "GreaterThanOrEqualToThreshold" \
        "${DIMENSIONS[@]}"

      create_alarm "$ALARM_PREFIX-P1-$ALARM_ID-EC2-Memory-90" \
        "P1: mem_used_percent >= 90% for 10 minutes on $DIMENSION_LABEL" \
        "CWAgent" "mem_used_percent" "Maximum" 300 2 2 90 "GreaterThanOrEqualToThreshold" \
        "${DIMENSIONS[@]}"
    done < <(echo "$MEMORY_METRICS" | jq -c '.[]')
  fi

  WINDOWS_MEMORY_METRICS=$(aws cloudwatch list-metrics \
    --region "$REGION" \
    --namespace "CWAgent" \
    --metric-name "Memory % Committed Bytes In Use" \
    --dimensions Name=InstanceId,Value="$INSTANCE_ID" \
    --query "Metrics[]" \
    --output json | preferred_instance_metric_dimensions "$INSTANCE_ID" "$INSTANCE_IMAGE_ID" "$INSTANCE_TYPE")

  if [ "$(echo "$WINDOWS_MEMORY_METRICS" | jq 'length')" -eq 0 ]; then
    echo "Skipping Windows memory alarms for $INSTANCE_ID (CWAgent Memory % Committed Bytes In Use not found)."
  else
    while read -r METRIC; do
      [ -z "$METRIC" ] && continue
      mapfile -t DIMENSIONS < <(echo "$METRIC" | metric_dimension_args)
      DIMENSION_LABEL=$(echo "$METRIC" | metric_dimension_label)
      ALARM_ID=$(echo "$INSTANCE_ID-$DIMENSION_LABEL" | safe_alarm_id | cut -c1-120)

      create_alarm "$ALARM_PREFIX-P2-$ALARM_ID-EC2-Windows-Memory-85" \
        "P2: Windows Memory % Committed Bytes In Use >= 85% for 15 minutes on $DIMENSION_LABEL" \
        "CWAgent" "Memory % Committed Bytes In Use" "Average" 300 3 3 85 "GreaterThanOrEqualToThreshold" \
        "${DIMENSIONS[@]}"

      create_alarm "$ALARM_PREFIX-P1-$ALARM_ID-EC2-Windows-Memory-90" \
        "P1: Windows Memory % Committed Bytes In Use >= 90% for 10 minutes on $DIMENSION_LABEL" \
        "CWAgent" "Memory % Committed Bytes In Use" "Maximum" 300 2 2 90 "GreaterThanOrEqualToThreshold" \
        "${DIMENSIONS[@]}"
    done < <(echo "$WINDOWS_MEMORY_METRICS" | jq -c '.[]')
  fi
done < <(echo "$RUNNING_INSTANCES_JSON" | jq -c '.[]')

echo "Discovering CloudWatch Agent disk metrics..."
delete_obsolete_linux_disk_alarms
DISK_METRICS=$(cwagent_linux_disk_metrics)

if [ "$(echo "$DISK_METRICS" | jq 'length')" -eq 0 ]; then
  echo "Skipping disk alarms (CloudWatch Agent not installed or not reporting)."
else
  while read -r METRIC; do
    [ -z "$METRIC" ] && continue
    mapfile -t DIMENSIONS < <(echo "$METRIC" | metric_dimension_args)
    DIMENSION_LABEL=$(echo "$METRIC" | metric_dimension_label)
    ALARM_ID=$(echo "$DIMENSION_LABEL" | safe_alarm_id | cut -c1-140)

    create_alarm "$ALARM_PREFIX-P2-$ALARM_ID-EC2-Disk-85" \
      "P2: disk_used_percent >= 85% for 15 minutes on $DIMENSION_LABEL" \
      "CWAgent" "disk_used_percent" "Average" 300 3 3 85 "GreaterThanOrEqualToThreshold" \
      "${DIMENSIONS[@]}"

    create_alarm "$ALARM_PREFIX-P1-$ALARM_ID-EC2-Disk-90" \
      "P1: disk_used_percent >= 90% for 10 minutes on $DIMENSION_LABEL" \
      "CWAgent" "disk_used_percent" "Maximum" 300 2 2 90 "GreaterThanOrEqualToThreshold" \
      "${DIMENSIONS[@]}"
  done < <(echo "$DISK_METRICS" | jq -c '.[]')
fi

echo "Discovering Windows CloudWatch Agent disk metrics..."
WINDOWS_DISK_METRICS=$(cwagent_windows_disk_metrics)

if [ "$(echo "$WINDOWS_DISK_METRICS" | jq 'length')" -eq 0 ]; then
  echo "Skipping Windows disk alarms (CWAgent LogicalDisk % Free Space not found)."
else
  while read -r METRIC; do
    [ -z "$METRIC" ] && continue
    mapfile -t DIMENSIONS < <(echo "$METRIC" | metric_dimension_args)
    DIMENSION_LABEL=$(echo "$METRIC" | metric_dimension_label)
    ALARM_ID=$(echo "$DIMENSION_LABEL" | safe_alarm_id | cut -c1-140)

    create_alarm "$ALARM_PREFIX-P2-$ALARM_ID-EC2-Windows-Disk-Free-15" \
      "P2: Windows LogicalDisk free space <= 15% for 15 minutes on $DIMENSION_LABEL" \
      "CWAgent" "LogicalDisk % Free Space" "Average" 300 3 3 15 "LessThanOrEqualToThreshold" \
      "${DIMENSIONS[@]}"

    create_alarm "$ALARM_PREFIX-P1-$ALARM_ID-EC2-Windows-Disk-Free-10" \
      "P1: Windows LogicalDisk free space <= 10% for 10 minutes on $DIMENSION_LABEL" \
      "CWAgent" "LogicalDisk % Free Space" "Minimum" 300 2 2 10 "LessThanOrEqualToThreshold" \
      "${DIMENSIONS[@]}"
  done < <(echo "$WINDOWS_DISK_METRICS" | jq -c '.[]')
fi

echo "Discovering RDS DB instances..."
RDS_DBS=$(aws rds describe-db-instances \
  --region "$REGION" \
  --query "DBInstances[].DBInstanceIdentifier" \
  --output text)

while read -r ROW; do
  DB=$(echo "$ROW" | jq -r '.')
  SAFE_DB=$(echo "$DB" | safe_alarm_id | cut -c1-120)

  create_alarm "$ALARM_PREFIX-P2-$SAFE_DB-RDS-CPU-80" \
    "P2: RDS CPUUtilization >= 80% for 15 minutes on $DB" \
    "AWS/RDS" "CPUUtilization" "Average" 300 3 3 80 "GreaterThanOrEqualToThreshold" \
    Name=DBInstanceIdentifier,Value="$DB"

  create_alarm "$ALARM_PREFIX-P1-$SAFE_DB-RDS-CPU-90" \
    "P1: RDS CPUUtilization >= 90% for 10 minutes on $DB" \
    "AWS/RDS" "CPUUtilization" "Maximum" 300 2 2 90 "GreaterThanOrEqualToThreshold" \
    Name=DBInstanceIdentifier,Value="$DB"
done < <(echo "$RDS_DBS" | text_items)

echo "Discovering EBS volumes..."
EBS_VOLUMES_JSON=$(aws ec2 describe-volumes \
  --region "$REGION" \
  --filters "Name=status,Values=in-use" \
  --query "Volumes[].{Id:VolumeId}" \
  --output json)

while read -r ROW; do
  VOLUME_ID=$(echo "$ROW" | jq -r '.Id')
  create_alarm "$ALARM_PREFIX-P1-$VOLUME_ID-EBS-StalledIO" \
    "P1: EBS VolumeStalledIOCheck >= 1 for 10 minutes on $VOLUME_ID" \
    "AWS/EBS" "VolumeStalledIOCheck" "Maximum" 300 2 2 1 "GreaterThanOrEqualToThreshold" \
    Name=VolumeId,Value="$VOLUME_ID"
done < <(echo "$EBS_VOLUMES_JSON" | jq -c '.[]')

echo "Discovering EFS file systems..."
EFS_FILE_SYSTEMS_JSON=$(aws efs describe-file-systems \
  --region "$REGION" \
  --query "FileSystems[].{Id:FileSystemId}" \
  --output json)

while read -r ROW; do
  EFS_ID=$(echo "$ROW" | jq -r '.Id')
  create_alarm "$ALARM_PREFIX-P2-$EFS_ID-EFS-PercentIOLimit-80" \
    "P2: EFS PercentIOLimit >= 80% for 15 minutes on $EFS_ID" \
    "AWS/EFS" "PercentIOLimit" "Average" 300 3 3 80 "GreaterThanOrEqualToThreshold" \
    Name=FileSystemId,Value="$EFS_ID"

  create_alarm "$ALARM_PREFIX-P1-$EFS_ID-EFS-PercentIOLimit-90" \
    "P1: EFS PercentIOLimit >= 90% for 10 minutes on $EFS_ID" \
    "AWS/EFS" "PercentIOLimit" "Maximum" 300 2 2 90 "GreaterThanOrEqualToThreshold" \
    Name=FileSystemId,Value="$EFS_ID"
done < <(echo "$EFS_FILE_SYSTEMS_JSON" | jq -c '.[]')

echo "Discovering Lambda functions..."
LAMBDA_FUNCTIONS=$(aws lambda list-functions \
  --region "$REGION" \
  --query "Functions[].FunctionName" \
  --output text)

while read -r ROW; do
  FUNCTION=$(echo "$ROW" | jq -r '.')
  SAFE_FUNCTION=$(echo "$FUNCTION" | safe_alarm_id | cut -c1-120)

  create_alarm "$ALARM_PREFIX-P2-$SAFE_FUNCTION-Lambda-Errors" \
    "P2: Lambda Errors >= 1 for 15 minutes on $FUNCTION" \
    "AWS/Lambda" "Errors" "Sum" 300 3 3 1 "GreaterThanOrEqualToThreshold" \
    Name=FunctionName,Value="$FUNCTION"

  create_alarm "$ALARM_PREFIX-P2-$SAFE_FUNCTION-Lambda-Throttles" \
    "P2: Lambda Throttles >= 1 for 15 minutes on $FUNCTION" \
    "AWS/Lambda" "Throttles" "Sum" 300 3 3 1 "GreaterThanOrEqualToThreshold" \
    Name=FunctionName,Value="$FUNCTION"
done < <(echo "$LAMBDA_FUNCTIONS" | text_items)

echo "Discovering Application Load Balancers..."
ALBS_JSON=$(aws elbv2 describe-load-balancers \
  --region "$REGION" \
  --query "LoadBalancers[?Type=='application'].{Name:LoadBalancerName,Arn:LoadBalancerArn}" \
  --output json | jq '[.[] | .Dimension = (.Arn | split("loadbalancer/")[1])]')

while read -r ROW; do
  ALB_NAME=$(echo "$ROW" | jq -r '.Name')
  ALB_DIMENSION=$(echo "$ROW" | jq -r '.Dimension')
  SAFE_ALB_NAME=$(echo "$ALB_NAME" | safe_alarm_id | cut -c1-120)

  create_alarm "$ALARM_PREFIX-P2-$SAFE_ALB_NAME-ALB-4XX" \
    "P2: ALB ELB 4XX count >= 100 for 15 minutes on $ALB_NAME" \
    "AWS/ApplicationELB" "HTTPCode_ELB_4XX_Count" "Sum" 300 3 3 100 "GreaterThanOrEqualToThreshold" \
    Name=LoadBalancer,Value="$ALB_DIMENSION"

  create_alarm "$ALARM_PREFIX-P2-$SAFE_ALB_NAME-ALB-5XX" \
    "P2: ALB ELB 5XX count >= 1 for 15 minutes on $ALB_NAME" \
    "AWS/ApplicationELB" "HTTPCode_ELB_5XX_Count" "Sum" 300 3 3 1 "GreaterThanOrEqualToThreshold" \
    Name=LoadBalancer,Value="$ALB_DIMENSION"

  create_alarm "$ALARM_PREFIX-P1-$SAFE_ALB_NAME-ALB-5XX" \
    "P1: ALB ELB 5XX count >= 5 for 10 minutes on $ALB_NAME" \
    "AWS/ApplicationELB" "HTTPCode_ELB_5XX_Count" "Sum" 300 2 2 5 "GreaterThanOrEqualToThreshold" \
    Name=LoadBalancer,Value="$ALB_DIMENSION"
done < <(echo "$ALBS_JSON" | jq -c '.[]')

TARGET_GROUPS_JSON=$(aws elbv2 describe-target-groups \
  --region "$REGION" \
  --query "TargetGroups[].{Name:TargetGroupName,Arn:TargetGroupArn,LoadBalancerArns:LoadBalancerArns}" \
  --output json | jq '[.[] | select((.LoadBalancerArns | length) > 0) | .TargetGroupDimension = (.Arn | split("targetgroup/")[1]) | .LoadBalancerDimension = (.LoadBalancerArns[0] | split("loadbalancer/")[1])]')

while read -r ROW; do
  TARGET_GROUP_NAME=$(echo "$ROW" | jq -r '.Name')
  TARGET_GROUP_DIMENSION=$(echo "$ROW" | jq -r '.TargetGroupDimension')
  TARGET_GROUP_LB_DIMENSION=$(echo "$ROW" | jq -r '.LoadBalancerDimension')
  SAFE_TG_NAME=$(echo "$TARGET_GROUP_NAME" | safe_alarm_id | cut -c1-120)

  create_alarm "$ALARM_PREFIX-P1-$SAFE_TG_NAME-ALB-UnhealthyHost" \
    "P1: ALB UnHealthyHostCount >= 1 for 10 minutes on target group $TARGET_GROUP_NAME" \
    "AWS/ApplicationELB" "UnHealthyHostCount" "Maximum" 300 2 2 1 "GreaterThanOrEqualToThreshold" \
    Name=TargetGroup,Value="$TARGET_GROUP_DIMENSION" Name=LoadBalancer,Value="$TARGET_GROUP_LB_DIMENSION"
done < <(echo "$TARGET_GROUPS_JSON" | jq -c '.[]')

echo "Discovering AWS Backup failed job metrics..."
BACKUP_FAILED_METRICS=$(aws cloudwatch list-metrics \
  --region "$REGION" \
  --namespace AWS/Backup \
  --metric-name NumberOfBackupJobsFailed \
  --query "Metrics[]" \
  --output json)

if [ "$(echo "$BACKUP_FAILED_METRICS" | jq 'length')" -eq 0 ]; then
  echo "Skipping AWS Backup alarms because NumberOfBackupJobsFailed metrics were not found."
fi

while read -r METRIC; do
  [ -z "$METRIC" ] && continue
  mapfile -t DIMENSIONS < <(echo "$METRIC" | metric_dimension_args)
  DIMENSION_LABEL=$(echo "$METRIC" | metric_dimension_label)
  ALARM_ID=$(echo "$DIMENSION_LABEL" | safe_alarm_id | cut -c1-140)

  create_alarm "$ALARM_PREFIX-P1-$ALARM_ID-Backup-Failed" \
    "P1: AWS Backup failed job detected for 10 minutes on $DIMENSION_LABEL" \
    "AWS/Backup" "NumberOfBackupJobsFailed" "Sum" 300 2 2 1 "GreaterThanOrEqualToThreshold" \
    "${DIMENSIONS[@]}"
done < <(echo "$BACKUP_FAILED_METRICS" | jq -c '.[]')

echo "CloudWatch alarm creation/update completed."
