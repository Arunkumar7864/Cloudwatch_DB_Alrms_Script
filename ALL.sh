#!/usr/bin/env bash

set -euo pipefail

REGION="${REGION:-eu-west-1}"
DASHBOARD_NAME="${DASHBOARD_NAME:-AWS-Compact-Monitoring}"
CUSTOMER_NAME="${CUSTOMER_NAME:-company_name}"
LOGO_URL="${LOGO_URL:-https://images.seeklogo.com/logo-png/49/1/al-baraka-bank-logo-png_seeklogo-496466.png}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

require_command aws
require_command jq

aws sts get-caller-identity --region "$REGION" >/dev/null

COLORS=(
  "#1f77b4" "#ff7f0e" "#2ca02c" "#d62728" "#9467bd" "#8c564b"
  "#e377c2" "#7f7f7f" "#bcbd22" "#17becf" "#aec7e8" "#ffbb78"
)

color_at() {
  local index="$1"
  echo "${COLORS[$((index % ${#COLORS[@]}))]}"
}

json_escape() {
  jq -Rn --arg value "$1" '$value'
}

metric_array() {
  local metrics="$1"
  echo "[${metrics%,}]"
}

echo "Discovering EC2 resources..."

EC2_RUNNING_COUNT=$(aws ec2 describe-instances --region "$REGION" --filters "Name=instance-state-name,Values=running" --query "length(Reservations[].Instances[])" --output text)
EC2_STOPPED_COUNT=$(aws ec2 describe-instances --region "$REGION" --filters "Name=instance-state-name,Values=stopped" --query "length(Reservations[].Instances[])" --output text)
EC2_STOPPING_COUNT=$(aws ec2 describe-instances --region "$REGION" --filters "Name=instance-state-name,Values=stopping" --query "length(Reservations[].Instances[])" --output text)
EC2_PENDING_COUNT=$(aws ec2 describe-instances --region "$REGION" --filters "Name=instance-state-name,Values=pending" --query "length(Reservations[].Instances[])" --output text)
EC2_TOTAL_COUNT=$((EC2_RUNNING_COUNT + EC2_STOPPED_COUNT + EC2_STOPPING_COUNT + EC2_PENDING_COUNT))

INSTANCES_JSON=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=instance-state-name,Values=running,stopped" \
  --query "Reservations[].Instances[].{Id:InstanceId,Name:Tags[?Key=='Name']|[0].Value,Type:InstanceType,ImageId:ImageId}" \
  --output json)
EC2_INSTANCE_METRIC_COUNT=$(echo "$INSTANCES_JSON" | jq 'length')

EC2_CPU_METRICS=""
EC2_MEMORY_METRICS=""
EC2_MEMORY_AVAILABLE_METRICS=""
EC2_MEMORY_AVAILABLE_PERCENT_METRICS=""
EC2_WINDOWS_MEMORY_USED_PERCENT_METRICS=""
EC2_WINDOWS_MEMORY_AVAILABLE_MB_METRICS=""
EC2_DISK_METRICS=""
EC2_WINDOWS_DISK_USED_PERCENT_METRICS=""
EC2_WINDOWS_DISK_FREE_PERCENT_METRICS=""
EC2_WINDOWS_DISK_FREE_MB_METRICS=""
EC2_DISK_USED_METRICS=""
EC2_DISK_FREE_METRICS=""
EC2_DISK_TOTAL_METRICS=""
EC2_STATUS_METRICS=""
EC2_NETWORK_METRICS=""
EC2_STATE_METRICS=""

EC2_INDEX=0
while read -r ROW; do
  INSTANCE_ID=$(echo "$ROW" | jq -r '.Id')
  INSTANCE_NAME=$(echo "$ROW" | jq -r '.Name // .Id')
  LABEL="$INSTANCE_NAME ($INSTANCE_ID)"
  COLOR=$(color_at "$EC2_INDEX")
  NETWORK_OUT_COLOR=$(color_at "$((EC2_INDEX + 1))")

  EC2_CPU_METRICS="$EC2_CPU_METRICS [\"AWS/EC2\",\"CPUUtilization\",\"InstanceId\",\"$INSTANCE_ID\",{\"label\":$(json_escape "$LABEL"),\"color\":\"$COLOR\"}],"
  EC2_STATUS_METRICS="$EC2_STATUS_METRICS [\"AWS/EC2\",\"StatusCheckFailed\",\"InstanceId\",\"$INSTANCE_ID\",{\"label\":$(json_escape "$LABEL"),\"color\":\"$COLOR\"}],"
  EC2_NETWORK_METRICS="$EC2_NETWORK_METRICS [\"AWS/EC2\",\"NetworkIn\",\"InstanceId\",\"$INSTANCE_ID\",{\"label\":$(json_escape "$LABEL NetworkIn"),\"color\":\"$COLOR\"}],[\".\",\"NetworkOut\",\".\",\"$INSTANCE_ID\",{\"label\":$(json_escape "$LABEL NetworkOut"),\"color\":\"$NETWORK_OUT_COLOR\"}],"
  EC2_INDEX=$((EC2_INDEX + 1))
done < <(echo "$INSTANCES_JSON" | jq -c '.[]')

cwagent_linux_disk_metric_arrays() {
  local metric_name="$1"

  aws cloudwatch list-metrics \
    --region "$REGION" \
    --namespace CWAgent \
    --metric-name "$metric_name" \
    --query "Metrics[].Dimensions" \
    --output json | jq -c --arg metric_name "$metric_name" --argjson instances "$INSTANCES_JSON" '
    def dim($name): (map(select(.Name == $name).Value) | first) // "";
    def lower_dim($name): (dim($name) | ascii_downcase);
    def dimension_names: [.[]?.Name] | sort;
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
    def disk_owner:
      if dim("InstanceId") != "" then dim("InstanceId") else dim("host") end;
    def disk_key:
      [
        disk_owner,
        lower_dim("path"),
        lower_dim("device"),
        lower_dim("fstype")
      ] | join("|");
    def dimension_label:
      sort_by(.Name) | map("\(.Name)=\(.Value)") | join(",");
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
    map(sort_by([preference_score, length, dimension_label]) | .[0]) |
    [
      .[] |
      ["CWAgent", $metric_name] +
      (sort_by(.Name) | map([.Name,.Value]) | add) +
      [{
        "label": ([disk_owner, dim("path"), dim("device")]
          | map(select(length > 0))
          | join(" / "))
      }]
    ]'
}

cwagent_windows_disk_metric_arrays() {
  local metric_name="$1"

  aws cloudwatch list-metrics \
    --region "$REGION" \
    --namespace CWAgent \
    --metric-name "$metric_name" \
    --query "Metrics[].Dimensions" \
    --output json | jq -c --arg metric_name "$metric_name" --argjson instances "$INSTANCES_JSON" '
    def dim($name): (map(select(.Name == $name).Value) | first) // "";
    def lower_dim($name): (dim($name) | ascii_downcase);
    def dimension_names: [.[]?.Name] | sort;
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
    def disk_owner:
      if dim("InstanceId") != "" then dim("InstanceId") else dim("host") end;
    def disk_key:
      [
        disk_owner,
        lower_dim("instance"),
        lower_dim("objectname")
      ] | join("|");
    def dimension_label:
      sort_by(.Name) | map("\(.Name)=\(.Value)") | join(",");
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
    map(sort_by([preference_score, length, dimension_label]) | .[0]) |
    [
      .[] |
      ["CWAgent", $metric_name] +
      (sort_by(.Name) | map([.Name,.Value]) | add) +
      [{
        "label": ([disk_owner, dim("instance")]
          | map(select(length > 0))
          | join(" / "))
      }]
    ]'
}

cwagent_windows_disk_used_percent_metric_arrays() {
  aws cloudwatch list-metrics \
    --region "$REGION" \
    --namespace CWAgent \
    --metric-name "LogicalDisk % Free Space" \
    --query "Metrics[].Dimensions" \
    --output json | jq -c --argjson instances "$INSTANCES_JSON" '
    def dim($name): (map(select(.Name == $name).Value) | first) // "";
    def lower_dim($name): (dim($name) | ascii_downcase);
    def dimension_names: [.[]?.Name] | sort;
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
    def disk_owner:
      if dim("InstanceId") != "" then dim("InstanceId") else dim("host") end;
    def disk_key:
      [
        disk_owner,
        lower_dim("instance"),
        lower_dim("objectname")
      ] | join("|");
    def dimension_label:
      sort_by(.Name) | map("\(.Name)=\(.Value)") | join(",");
    def disk_label:
      [disk_owner, dim("instance")]
      | map(select(length > 0))
      | join(" / ");
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
    map(sort_by([preference_score, length, dimension_label]) | .[0]) |
    [
      to_entries[] |
      (.key + 1) as $n |
      (.value | sort_by(.Name) | map([.Name,.Value]) | add) as $dimensions |
      (.value | disk_label) as $label |
      [
        ["CWAgent","LogicalDisk % Free Space"] + $dimensions + [{"id": ("wfree" + ($n | tostring)), "label": ($label + " Free %"), "visible": false}],
        [{"expression": ("100 - wfree" + ($n | tostring)), "label": ($label + " Used %"), "id": ("wused" + ($n | tostring))}]
      ]
    ] | flatten(1)'
}

cwagent_instance_metric_arrays() {
  local metric_name="$1"
  local label_suffix="$2"

  aws cloudwatch list-metrics \
    --region "$REGION" \
    --namespace CWAgent \
    --metric-name "$metric_name" \
    --query "Metrics[].Dimensions" \
    --output json | jq -c --arg metric_name "$metric_name" --arg label_suffix "$label_suffix" --argjson instances "$INSTANCES_JSON" '
    def dim($name): (map(select(.Name == $name).Value) | first) // "";
    def dimension_names: [.[]?.Name] | sort;
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
    def metric_owner:
      if dim("InstanceId") != "" then dim("InstanceId") else dim("host") end;
    def dimension_label:
      sort_by(.Name) | map("\(.Name)=\(.Value)") | join(",");
    def preference_score:
      if exact_dims(["InstanceId"]) then 0
      elif exact_dims(["InstanceId", "ImageId", "InstanceType"]) and has_current_instance_identity then 1
      elif has_dims(["InstanceId", "ImageId", "InstanceType"]) and has_current_instance_identity then 2
      elif exact_dims(["host"]) then 3
      elif has_dims(["host"]) then 4
      else 9
      end;

    [
      .[] |
      select(metric_owner != "" and has_current_instance_id)
    ] |
    group_by(metric_owner) |
    map(sort_by([preference_score, length, dimension_label]) | .[0]) |
    [
      .[] |
      ["CWAgent", $metric_name] +
      (sort_by(.Name) | map([.Name,.Value]) | add) +
      [{
        "label": ([metric_owner, $label_suffix]
          | map(select(length > 0))
          | join(" / "))
      }]
    ]'
}

backup_metric_arrays() {
  local metric_name="$1"
  local label_suffix="$2"
  local color="$3"

  aws cloudwatch list-metrics \
    --region "$REGION" \
    --namespace AWS/Backup \
    --metric-name "$metric_name" \
    --query "Metrics[].Dimensions" \
    --output json | jq -c --arg metric_name "$metric_name" --arg label_suffix "$label_suffix" --arg color "$color" '
    def dimension_key:
      sort_by(.Name) | map("\(.Name)=\(.Value)") | join("|");
    def dimension_values:
      sort_by(.Name) | map(.Value) | join(" / ");

    [
      .[] |
      select(length > 0)
    ] |
    group_by(dimension_key) |
    map(.[0]) |
    [
      .[] |
      ["AWS/Backup", $metric_name] +
      (sort_by(.Name) | map([.Name,.Value]) | add) +
      [{"label": ((dimension_values) + " " + $label_suffix), "color": $color}]
    ]'
}

EC2_DISK_METRICS=$(cwagent_linux_disk_metric_arrays disk_used_percent)

EC2_WINDOWS_DISK_FREE_PERCENT_METRICS=$(cwagent_windows_disk_metric_arrays "LogicalDisk % Free Space")

EC2_WINDOWS_DISK_USED_PERCENT_METRICS=$(cwagent_windows_disk_used_percent_metric_arrays)

EC2_WINDOWS_DISK_FREE_MB_METRICS=$(cwagent_windows_disk_metric_arrays "LogicalDisk Free Megabytes")

EC2_DISK_USED_METRICS=$(cwagent_linux_disk_metric_arrays disk_used)

EC2_DISK_FREE_METRICS=$(cwagent_linux_disk_metric_arrays disk_free)

EC2_DISK_TOTAL_METRICS=$(cwagent_linux_disk_metric_arrays disk_total)

EC2_MEMORY_METRICS=$(cwagent_instance_metric_arrays mem_used_percent "Memory Used %")

EC2_MEMORY_AVAILABLE_METRICS=$(cwagent_instance_metric_arrays mem_available "Memory Available")

EC2_MEMORY_AVAILABLE_PERCENT_METRICS=$(cwagent_instance_metric_arrays mem_available_percent "Memory Available %")

EC2_WINDOWS_MEMORY_USED_PERCENT_METRICS=$(cwagent_instance_metric_arrays "Memory % Committed Bytes In Use" "Windows Memory Used %")

EC2_WINDOWS_MEMORY_AVAILABLE_MB_METRICS=$(cwagent_instance_metric_arrays "Memory Available MBytes" "Windows Memory Available MB")

EC2_STATE_METRICS="[
  [ { \"expression\": \"TIME_SERIES($EC2_RUNNING_COUNT)\", \"label\": \"Running\", \"id\": \"ec2running\", \"color\": \"#2ca02c\" } ],
  [ { \"expression\": \"TIME_SERIES($EC2_STOPPED_COUNT)\", \"label\": \"Stopped\", \"id\": \"ec2stopped\", \"color\": \"#7f7f7f\" } ],
  [ { \"expression\": \"TIME_SERIES($EC2_STOPPING_COUNT)\", \"label\": \"Stopping\", \"id\": \"ec2stopping\", \"color\": \"#ff7f0e\" } ],
  [ { \"expression\": \"TIME_SERIES($EC2_PENDING_COUNT)\", \"label\": \"Pending\", \"id\": \"ec2pending\", \"color\": \"#1f77b4\" } ]
]"

echo "Discovering EBS volumes..."

EBS_TOTAL_COUNT=$(aws ec2 describe-volumes --region "$REGION" --query "length(Volumes[])" --output text)
EBS_ATTACHED_COUNT=$(aws ec2 describe-volumes --region "$REGION" --filters "Name=status,Values=in-use" --query "length(Volumes[])" --output text)
EBS_AVAILABLE_COUNT=$(aws ec2 describe-volumes --region "$REGION" --filters "Name=status,Values=available" --query "length(Volumes[])" --output text)
EBS_VOLUMES_JSON=$(aws ec2 describe-volumes \
  --region "$REGION" \
  --filters "Name=status,Values=in-use" \
  --query "Volumes[].{Id:VolumeId,Name:Tags[?Key=='Name']|[0].Value}" \
  --output json)
EBS_ATTACHED_METRIC_COUNT=$(echo "$EBS_VOLUMES_JSON" | jq 'length')
EBS_READ_BYTES_METRICS=""
EBS_WRITE_BYTES_METRICS=""
EBS_READ_OPS_METRICS=""
EBS_WRITE_OPS_METRICS=""
EBS_STALLED_IO_METRICS=""
EBS_STATE_METRICS="[
  [ { \"expression\": \"TIME_SERIES($EBS_ATTACHED_COUNT)\", \"label\": \"Attached\", \"id\": \"ebsattached\", \"color\": \"#2ca02c\" } ],
  [ { \"expression\": \"TIME_SERIES($EBS_AVAILABLE_COUNT)\", \"label\": \"Available\", \"id\": \"ebsavailable\", \"color\": \"#7f7f7f\" } ]
]"

EBS_INDEX=0
while read -r ROW; do
  VOLUME_ID=$(echo "$ROW" | jq -r '.Id')
  VOLUME_NAME=$(echo "$ROW" | jq -r '.Name // .Id')
  LABEL="$VOLUME_NAME ($VOLUME_ID)"
  COLOR=$(color_at "$EBS_INDEX")
  WRITE_COLOR=$(color_at "$((EBS_INDEX + 1))")

  EBS_READ_BYTES_METRICS="$EBS_READ_BYTES_METRICS [\"AWS/EBS\",\"VolumeReadBytes\",\"VolumeId\",\"$VOLUME_ID\",{\"label\":$(json_escape "$LABEL Read Bytes"),\"color\":\"$COLOR\"}],"
  EBS_WRITE_BYTES_METRICS="$EBS_WRITE_BYTES_METRICS [\"AWS/EBS\",\"VolumeWriteBytes\",\"VolumeId\",\"$VOLUME_ID\",{\"label\":$(json_escape "$LABEL Write Bytes"),\"color\":\"$WRITE_COLOR\"}],"
  EBS_READ_OPS_METRICS="$EBS_READ_OPS_METRICS [\"AWS/EBS\",\"VolumeReadOps\",\"VolumeId\",\"$VOLUME_ID\",{\"label\":$(json_escape "$LABEL Read Ops"),\"color\":\"$COLOR\"}],"
  EBS_WRITE_OPS_METRICS="$EBS_WRITE_OPS_METRICS [\"AWS/EBS\",\"VolumeWriteOps\",\"VolumeId\",\"$VOLUME_ID\",{\"label\":$(json_escape "$LABEL Write Ops"),\"color\":\"$WRITE_COLOR\"}],"
  EBS_STALLED_IO_METRICS="$EBS_STALLED_IO_METRICS [\"AWS/EBS\",\"VolumeStalledIOCheck\",\"VolumeId\",\"$VOLUME_ID\",{\"label\":$(json_escape "$LABEL Stalled IO"),\"color\":\"#d62728\"}],"
  EBS_INDEX=$((EBS_INDEX + 1))
done < <(echo "$EBS_VOLUMES_JSON" | jq -c '.[]')

echo "Discovering EFS file systems..."

EFS_FILE_SYSTEMS_JSON=$(aws efs describe-file-systems \
  --region "$REGION" \
  --query "FileSystems[].{Id:FileSystemId,Name:Name}" \
  --output json)
EFS_FILE_SYSTEM_COUNT=$(echo "$EFS_FILE_SYSTEMS_JSON" | jq 'length')
EFS_READ_BYTES_METRICS=""
EFS_WRITE_BYTES_METRICS=""
EFS_TOTAL_IO_METRICS=""
EFS_PERCENT_IO_METRICS=""
EFS_BURST_CREDIT_METRICS=""
EFS_CLIENT_CONNECTION_METRICS=""

EFS_INDEX=0
while read -r ROW; do
  EFS_ID=$(echo "$ROW" | jq -r '.Id')
  EFS_NAME=$(echo "$ROW" | jq -r '.Name // .Id')
  LABEL="$EFS_NAME ($EFS_ID)"
  COLOR=$(color_at "$EFS_INDEX")
  WRITE_COLOR=$(color_at "$((EFS_INDEX + 1))")

  EFS_READ_BYTES_METRICS="$EFS_READ_BYTES_METRICS [\"AWS/EFS\",\"DataReadIOBytes\",\"FileSystemId\",\"$EFS_ID\",{\"label\":$(json_escape "$LABEL Read Bytes"),\"color\":\"$COLOR\"}],"
  EFS_WRITE_BYTES_METRICS="$EFS_WRITE_BYTES_METRICS [\"AWS/EFS\",\"DataWriteIOBytes\",\"FileSystemId\",\"$EFS_ID\",{\"label\":$(json_escape "$LABEL Write Bytes"),\"color\":\"$WRITE_COLOR\"}],"
  EFS_TOTAL_IO_METRICS="$EFS_TOTAL_IO_METRICS [\"AWS/EFS\",\"TotalIOBytes\",\"FileSystemId\",\"$EFS_ID\",{\"label\":$(json_escape "$LABEL Total IO"),\"color\":\"$COLOR\"}],"
  EFS_PERCENT_IO_METRICS="$EFS_PERCENT_IO_METRICS [\"AWS/EFS\",\"PercentIOLimit\",\"FileSystemId\",\"$EFS_ID\",{\"label\":$(json_escape "$LABEL IO Limit %"),\"color\":\"$COLOR\"}],"
  EFS_BURST_CREDIT_METRICS="$EFS_BURST_CREDIT_METRICS [\"AWS/EFS\",\"BurstCreditBalance\",\"FileSystemId\",\"$EFS_ID\",{\"label\":$(json_escape "$LABEL Burst Credits"),\"color\":\"$COLOR\"}],"
  EFS_CLIENT_CONNECTION_METRICS="$EFS_CLIENT_CONNECTION_METRICS [\"AWS/EFS\",\"ClientConnections\",\"FileSystemId\",\"$EFS_ID\",{\"label\":$(json_escape "$LABEL Connections"),\"color\":\"$COLOR\"}],"
  EFS_INDEX=$((EFS_INDEX + 1))
done < <(echo "$EFS_FILE_SYSTEMS_JSON" | jq -c '.[]')

echo "Discovering FSx file systems..."

FSX_FILE_SYSTEMS_JSON=$(aws fsx describe-file-systems \
  --region "$REGION" \
  --query "FileSystems[].{Id:FileSystemId,Type:FileSystemType}" \
  --output json)
FSX_FILE_SYSTEM_COUNT=$(echo "$FSX_FILE_SYSTEMS_JSON" | jq 'length')
FSX_READ_BYTES_METRICS=""
FSX_WRITE_BYTES_METRICS=""
FSX_READ_OPS_METRICS=""
FSX_WRITE_OPS_METRICS=""
FSX_FREE_STORAGE_METRICS=""

FSX_INDEX=0
while read -r ROW; do
  FSX_ID=$(echo "$ROW" | jq -r '.Id')
  FSX_TYPE=$(echo "$ROW" | jq -r '.Type // "FSx"')
  LABEL="$FSX_TYPE ($FSX_ID)"
  COLOR=$(color_at "$FSX_INDEX")
  WRITE_COLOR=$(color_at "$((FSX_INDEX + 1))")

  FSX_READ_BYTES_METRICS="$FSX_READ_BYTES_METRICS [\"AWS/FSx\",\"DataReadBytes\",\"FileSystemId\",\"$FSX_ID\",{\"label\":$(json_escape "$LABEL Read Bytes"),\"color\":\"$COLOR\"}],"
  FSX_WRITE_BYTES_METRICS="$FSX_WRITE_BYTES_METRICS [\"AWS/FSx\",\"DataWriteBytes\",\"FileSystemId\",\"$FSX_ID\",{\"label\":$(json_escape "$LABEL Write Bytes"),\"color\":\"$WRITE_COLOR\"}],"
  FSX_READ_OPS_METRICS="$FSX_READ_OPS_METRICS [\"AWS/FSx\",\"DataReadOperations\",\"FileSystemId\",\"$FSX_ID\",{\"label\":$(json_escape "$LABEL Read Ops"),\"color\":\"$COLOR\"}],"
  FSX_WRITE_OPS_METRICS="$FSX_WRITE_OPS_METRICS [\"AWS/FSx\",\"DataWriteOperations\",\"FileSystemId\",\"$FSX_ID\",{\"label\":$(json_escape "$LABEL Write Ops"),\"color\":\"$WRITE_COLOR\"}],"
  FSX_FREE_STORAGE_METRICS="$FSX_FREE_STORAGE_METRICS [\"AWS/FSx\",\"FreeStorageCapacity\",\"FileSystemId\",\"$FSX_ID\",{\"label\":$(json_escape "$LABEL Free Storage"),\"color\":\"$COLOR\"}],"
  FSX_INDEX=$((FSX_INDEX + 1))
done < <(echo "$FSX_FILE_SYSTEMS_JSON" | jq -c '.[]')

echo "Discovering ECS resources..."

ECS_CLUSTERS=$(aws ecs list-clusters --region "$REGION" --query "clusterArns[]" --output text)
ECS_CLUSTER_COUNT=$(echo "$ECS_CLUSTERS" | wc -w)
ECS_SERVICE_COUNT=0
ECS_RUNNING_TASKS=0
ECS_PENDING_TASKS=0
ECS_CONTAINER_INSTANCES=0
ECS_CPU_METRICS=""
ECS_MEMORY_METRICS=""
ECS_RUNNING_TASK_METRICS=""
ECS_PENDING_TASK_METRICS=""
ECS_SUMMARY_METRICS=""

ECS_INDEX=0
for CLUSTER_ARN in $ECS_CLUSTERS; do
  CLUSTER_NAME=$(basename "$CLUSTER_ARN")
  CLUSTER_DESC=$(aws ecs describe-clusters --region "$REGION" --clusters "$CLUSTER_ARN" --query "clusters[0]" --output json)
  ECS_CONTAINER_INSTANCES=$((ECS_CONTAINER_INSTANCES + $(echo "$CLUSTER_DESC" | jq -r '.registeredContainerInstancesCount // 0')))

  SERVICES=$(aws ecs list-services --region "$REGION" --cluster "$CLUSTER_ARN" --query "serviceArns[]" --output text)
  for SERVICE_ARN in $SERVICES; do
    SERVICE_NAME=$(basename "$SERVICE_ARN")
    LABEL="$CLUSTER_NAME / $SERVICE_NAME"
    ECS_SERVICE_COUNT=$((ECS_SERVICE_COUNT + 1))

    SERVICE_DESC=$(aws ecs describe-services --region "$REGION" --cluster "$CLUSTER_ARN" --services "$SERVICE_ARN" --query "services[0]" --output json)
    ECS_RUNNING_TASKS=$((ECS_RUNNING_TASKS + $(echo "$SERVICE_DESC" | jq -r '.runningCount // 0')))
    ECS_PENDING_TASKS=$((ECS_PENDING_TASKS + $(echo "$SERVICE_DESC" | jq -r '.pendingCount // 0')))

    COLOR=$(color_at "$ECS_INDEX")
    ECS_CPU_METRICS="$ECS_CPU_METRICS [\"AWS/ECS\",\"CPUUtilization\",\"ClusterName\",\"$CLUSTER_NAME\",\"ServiceName\",\"$SERVICE_NAME\",{\"label\":$(json_escape "$LABEL"),\"color\":\"$COLOR\"}],"
    ECS_MEMORY_METRICS="$ECS_MEMORY_METRICS [\"AWS/ECS\",\"MemoryUtilization\",\"ClusterName\",\"$CLUSTER_NAME\",\"ServiceName\",\"$SERVICE_NAME\",{\"label\":$(json_escape "$LABEL"),\"color\":\"$COLOR\"}],"
    ECS_RUNNING_TASK_METRICS="$ECS_RUNNING_TASK_METRICS [\"ECS/ContainerInsights\",\"RunningTaskCount\",\"ClusterName\",\"$CLUSTER_NAME\",\"ServiceName\",\"$SERVICE_NAME\",{\"label\":$(json_escape "$LABEL"),\"color\":\"$COLOR\"}],"
    ECS_PENDING_TASK_METRICS="$ECS_PENDING_TASK_METRICS [\"ECS/ContainerInsights\",\"PendingTaskCount\",\"ClusterName\",\"$CLUSTER_NAME\",\"ServiceName\",\"$SERVICE_NAME\",{\"label\":$(json_escape "$LABEL"),\"color\":\"$COLOR\"}],"
    ECS_INDEX=$((ECS_INDEX + 1))
  done
done

ECS_SUMMARY_METRICS="[
  [ { \"expression\": \"TIME_SERIES($ECS_CLUSTER_COUNT)\", \"label\": \"Clusters\", \"id\": \"ecsclusters\", \"color\": \"#1f77b4\" } ],
  [ { \"expression\": \"TIME_SERIES($ECS_SERVICE_COUNT)\", \"label\": \"Services\", \"id\": \"ecsservices\", \"color\": \"#17becf\" } ],
  [ { \"expression\": \"TIME_SERIES($ECS_RUNNING_TASKS)\", \"label\": \"Running Tasks\", \"id\": \"ecsrunningtasks\", \"color\": \"#2ca02c\" } ],
  [ { \"expression\": \"TIME_SERIES($ECS_PENDING_TASKS)\", \"label\": \"Pending Tasks\", \"id\": \"ecspendingtasks\", \"color\": \"#ff7f0e\" } ],
  [ { \"expression\": \"TIME_SERIES($ECS_CONTAINER_INSTANCES)\", \"label\": \"Container Instances\", \"id\": \"ecscontainerinstances\", \"color\": \"#9467bd\" } ]
]"

echo "Discovering EKS resources..."

EKS_CLUSTERS=$(aws eks list-clusters --region "$REGION" --query "clusters[]" --output text)
EKS_CLUSTER_COUNT=$(echo "$EKS_CLUSTERS" | wc -w)
EKS_TOTAL_NODES=0
EKS_RUNNING_NODES=0
EKS_STOPPED_NODES=0
EKS_CPU_METRICS=""
EKS_MEMORY_METRICS=""
EKS_FILESYSTEM_METRICS=""
EKS_POD_METRICS=""
EKS_SUMMARY_METRICS=""

EKS_INDEX=0
for CLUSTER in $EKS_CLUSTERS; do
  RUNNING_FOR_CLUSTER=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:kubernetes.io/cluster/$CLUSTER,Values=owned,shared" "Name=instance-state-name,Values=running" \
    --query "length(Reservations[].Instances[])" \
    --output text)

  STOPPED_FOR_CLUSTER=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:kubernetes.io/cluster/$CLUSTER,Values=owned,shared" "Name=instance-state-name,Values=stopped" \
    --query "length(Reservations[].Instances[])" \
    --output text)

  EKS_RUNNING_NODES=$((EKS_RUNNING_NODES + RUNNING_FOR_CLUSTER))
  EKS_STOPPED_NODES=$((EKS_STOPPED_NODES + STOPPED_FOR_CLUSTER))
  EKS_TOTAL_NODES=$((EKS_TOTAL_NODES + RUNNING_FOR_CLUSTER + STOPPED_FOR_CLUSTER))

  COLOR=$(color_at "$EKS_INDEX")
  EKS_CPU_METRICS="$EKS_CPU_METRICS [\"ContainerInsights\",\"node_cpu_utilization\",\"ClusterName\",\"$CLUSTER\",{\"label\":$(json_escape "$CLUSTER CPU"),\"color\":\"$COLOR\"}],"
  EKS_MEMORY_METRICS="$EKS_MEMORY_METRICS [\"ContainerInsights\",\"node_memory_utilization\",\"ClusterName\",\"$CLUSTER\",{\"label\":$(json_escape "$CLUSTER Memory"),\"color\":\"$COLOR\"}],"
  EKS_FILESYSTEM_METRICS="$EKS_FILESYSTEM_METRICS [\"ContainerInsights\",\"node_filesystem_utilization\",\"ClusterName\",\"$CLUSTER\",{\"label\":$(json_escape "$CLUSTER Filesystem"),\"color\":\"$COLOR\"}],"
  EKS_POD_METRICS="$EKS_POD_METRICS [\"ContainerInsights\",\"pod_number_of_running_pods\",\"ClusterName\",\"$CLUSTER\",{\"label\":$(json_escape "$CLUSTER Running Pods"),\"color\":\"$COLOR\"}],"
  EKS_INDEX=$((EKS_INDEX + 1))
done

EKS_SUMMARY_METRICS="[
  [ { \"expression\": \"TIME_SERIES($EKS_CLUSTER_COUNT)\", \"label\": \"Clusters\", \"id\": \"eksclusters\", \"color\": \"#1f77b4\" } ],
  [ { \"expression\": \"TIME_SERIES($EKS_TOTAL_NODES)\", \"label\": \"Total Nodes\", \"id\": \"ekstotalnodes\", \"color\": \"#17becf\" } ],
  [ { \"expression\": \"TIME_SERIES($EKS_RUNNING_NODES)\", \"label\": \"Running Nodes\", \"id\": \"eksrunningnodes\", \"color\": \"#2ca02c\" } ],
  [ { \"expression\": \"TIME_SERIES($EKS_STOPPED_NODES)\", \"label\": \"Stopped Nodes\", \"id\": \"eksstoppednodes\", \"color\": \"#7f7f7f\" } ]
]"

echo "Discovering Lambda resources..."

LAMBDA_FUNCTIONS=$(aws lambda list-functions --region "$REGION" --query "Functions[].FunctionName" --output text)
LAMBDA_FUNCTION_COUNT=$(echo "$LAMBDA_FUNCTIONS" | wc -w)
LAMBDA_INVOCATIONS_METRICS=""
LAMBDA_ERRORS_METRICS=""
LAMBDA_DURATION_METRICS=""
LAMBDA_THROTTLES_METRICS=""

LAMBDA_INDEX=0
for FUNCTION in $LAMBDA_FUNCTIONS; do
  COLOR=$(color_at "$LAMBDA_INDEX")
  LAMBDA_INVOCATIONS_METRICS="$LAMBDA_INVOCATIONS_METRICS [\"AWS/Lambda\",\"Invocations\",\"FunctionName\",\"$FUNCTION\",{\"label\":$(json_escape "$FUNCTION"),\"color\":\"$COLOR\"}],"
  LAMBDA_ERRORS_METRICS="$LAMBDA_ERRORS_METRICS [\"AWS/Lambda\",\"Errors\",\"FunctionName\",\"$FUNCTION\",{\"label\":$(json_escape "$FUNCTION"),\"color\":\"$COLOR\"}],"
  LAMBDA_DURATION_METRICS="$LAMBDA_DURATION_METRICS [\"AWS/Lambda\",\"Duration\",\"FunctionName\",\"$FUNCTION\",{\"label\":$(json_escape "$FUNCTION"),\"color\":\"$COLOR\"}],"
  LAMBDA_THROTTLES_METRICS="$LAMBDA_THROTTLES_METRICS [\"AWS/Lambda\",\"Throttles\",\"FunctionName\",\"$FUNCTION\",{\"label\":$(json_escape "$FUNCTION"),\"color\":\"$COLOR\"}],"
  LAMBDA_INDEX=$((LAMBDA_INDEX + 1))
done

echo "Discovering Application Load Balancers..."

ALBS_JSON=$(aws elbv2 describe-load-balancers \
  --region "$REGION" \
  --query "LoadBalancers[?Type=='application'].{Name:LoadBalancerName,Arn:LoadBalancerArn}" \
  --output json | jq '[.[] | .Dimension = (.Arn | split("loadbalancer/")[1])]')
ALB_COUNT=$(echo "$ALBS_JSON" | jq 'length')
ALB_REQUEST_METRICS=""
ALB_4XX_METRICS=""
ALB_5XX_METRICS=""
ALB_RESPONSE_TIME_METRICS=""
ALB_HEALTHY_HOST_METRICS=""
ALB_UNHEALTHY_HOST_METRICS=""

ALB_INDEX=0
while read -r ROW; do
  ALB_NAME=$(echo "$ROW" | jq -r '.Name')
  ALB_DIMENSION=$(echo "$ROW" | jq -r '.Dimension')
  COLOR=$(color_at "$ALB_INDEX")
  ERROR_COLOR=$(color_at "$((ALB_INDEX + 1))")

  ALB_REQUEST_METRICS="$ALB_REQUEST_METRICS [\"AWS/ApplicationELB\",\"RequestCount\",\"LoadBalancer\",\"$ALB_DIMENSION\",{\"label\":$(json_escape "$ALB_NAME"),\"color\":\"$COLOR\"}],"
  ALB_4XX_METRICS="$ALB_4XX_METRICS [\"AWS/ApplicationELB\",\"HTTPCode_ELB_4XX_Count\",\"LoadBalancer\",\"$ALB_DIMENSION\",{\"label\":$(json_escape "$ALB_NAME ELB 4XX"),\"color\":\"$COLOR\"}],[\".\",\"HTTPCode_Target_4XX_Count\",\".\",\".\",{\"label\":$(json_escape "$ALB_NAME Target 4XX"),\"color\":\"$ERROR_COLOR\"}],"
  ALB_5XX_METRICS="$ALB_5XX_METRICS [\"AWS/ApplicationELB\",\"HTTPCode_ELB_5XX_Count\",\"LoadBalancer\",\"$ALB_DIMENSION\",{\"label\":$(json_escape "$ALB_NAME ELB 5XX"),\"color\":\"$COLOR\"}],[\".\",\"HTTPCode_Target_5XX_Count\",\".\",\".\",{\"label\":$(json_escape "$ALB_NAME Target 5XX"),\"color\":\"$ERROR_COLOR\"}],"
  ALB_RESPONSE_TIME_METRICS="$ALB_RESPONSE_TIME_METRICS [\"AWS/ApplicationELB\",\"TargetResponseTime\",\"LoadBalancer\",\"$ALB_DIMENSION\",{\"label\":$(json_escape "$ALB_NAME"),\"color\":\"$COLOR\"}],"
  ALB_INDEX=$((ALB_INDEX + 1))
done < <(echo "$ALBS_JSON" | jq -c '.[]')

TARGET_GROUPS_JSON=$(aws elbv2 describe-target-groups \
  --region "$REGION" \
  --query "TargetGroups[].{Name:TargetGroupName,Arn:TargetGroupArn,LoadBalancerArns:LoadBalancerArns}" \
  --output json | jq '[.[] | select((.LoadBalancerArns | length) > 0) | .TargetGroupDimension = (.Arn | split("targetgroup/")[1]) | .LoadBalancerDimension = (.LoadBalancerArns[0] | split("loadbalancer/")[1])]')
TARGET_GROUP_COUNT=$(echo "$TARGET_GROUPS_JSON" | jq 'length')

TG_INDEX=0
while read -r ROW; do
  TARGET_GROUP_NAME=$(echo "$ROW" | jq -r '.Name')
  TARGET_GROUP_DIMENSION=$(echo "$ROW" | jq -r '.TargetGroupDimension')
  TARGET_GROUP_LB_DIMENSION=$(echo "$ROW" | jq -r '.LoadBalancerDimension')
  COLOR=$(color_at "$TG_INDEX")

  ALB_HEALTHY_HOST_METRICS="$ALB_HEALTHY_HOST_METRICS [\"AWS/ApplicationELB\",\"HealthyHostCount\",\"TargetGroup\",\"$TARGET_GROUP_DIMENSION\",\"LoadBalancer\",\"$TARGET_GROUP_LB_DIMENSION\",{\"label\":$(json_escape "$TARGET_GROUP_NAME Healthy"),\"color\":\"$COLOR\"}],"
  ALB_UNHEALTHY_HOST_METRICS="$ALB_UNHEALTHY_HOST_METRICS [\"AWS/ApplicationELB\",\"UnHealthyHostCount\",\"TargetGroup\",\"$TARGET_GROUP_DIMENSION\",\"LoadBalancer\",\"$TARGET_GROUP_LB_DIMENSION\",{\"label\":$(json_escape "$TARGET_GROUP_NAME Unhealthy"),\"color\":\"$COLOR\"}],"
  TG_INDEX=$((TG_INDEX + 1))
done < <(echo "$TARGET_GROUPS_JSON" | jq -c '.[]')

echo "Discovering RDS resources..."

RDS_DBS=$(aws rds describe-db-instances --region "$REGION" --query "DBInstances[].DBInstanceIdentifier" --output text)
RDS_DB_COUNT=$(echo "$RDS_DBS" | wc -w)
RDS_CPU_METRICS=""
RDS_STORAGE_METRICS=""
RDS_LATENCY_METRICS=""
RDS_CONN_METRICS=""

RDS_INDEX=0
for DB in $RDS_DBS; do
  COLOR=$(color_at "$RDS_INDEX")
  WRITE_COLOR=$(color_at "$((RDS_INDEX + 1))")
  RDS_CPU_METRICS="$RDS_CPU_METRICS [\"AWS/RDS\",\"CPUUtilization\",\"DBInstanceIdentifier\",\"$DB\",{\"label\":$(json_escape "$DB"),\"color\":\"$COLOR\"}],"
  RDS_STORAGE_METRICS="$RDS_STORAGE_METRICS [\"AWS/RDS\",\"FreeStorageSpace\",\"DBInstanceIdentifier\",\"$DB\",{\"label\":$(json_escape "$DB"),\"color\":\"$COLOR\"}],"
  RDS_LATENCY_METRICS="$RDS_LATENCY_METRICS [\"AWS/RDS\",\"ReadLatency\",\"DBInstanceIdentifier\",\"$DB\",{\"label\":$(json_escape "$DB Read"),\"color\":\"$COLOR\"}],[\".\",\"WriteLatency\",\".\",\".\",{\"label\":$(json_escape "$DB Write"),\"color\":\"$WRITE_COLOR\"}],"
  RDS_CONN_METRICS="$RDS_CONN_METRICS [\"AWS/RDS\",\"DatabaseConnections\",\"DBInstanceIdentifier\",\"$DB\",{\"label\":$(json_escape "$DB"),\"color\":\"$COLOR\"}],"
  RDS_INDEX=$((RDS_INDEX + 1))
done

echo "Discovering AWS Backup metrics..."

BACKUP_COMPLETED_METRICS=$(backup_metric_arrays NumberOfBackupJobsCompleted Completed "#2ca02c")

BACKUP_FAILED_METRICS=$(backup_metric_arrays NumberOfBackupJobsFailed Failed "#d62728")

BACKUP_COMPLETED_METRIC_COUNT=$(echo "$BACKUP_COMPLETED_METRICS" | jq 'length')
BACKUP_FAILED_METRIC_COUNT=$(echo "$BACKUP_FAILED_METRICS" | jq 'length')
BACKUP_METRIC_COUNT=$((BACKUP_COMPLETED_METRIC_COUNT + BACKUP_FAILED_METRIC_COUNT))

WIDGETS=$(cat <<EOF
    { "type": "text", "x": 0, "y": 0, "width": 24, "height": 1, "properties": { "markdown": "# AWS Compact Monitoring - $CUSTOMER_NAME" } }
EOF
)

NEXT_Y=1

append_widget() {
  WIDGETS="$WIDGETS,
$1"
}

append_summary_widget() {
  local title="$1"
  local count="$2"

  if [ "$NEXT_SUMMARY_X" -ge 24 ]; then
    NEXT_SUMMARY_X=0
    NEXT_Y=$((NEXT_Y + 3))
  fi

  append_widget "$(cat <<EOF
    { "type": "text", "x": $NEXT_SUMMARY_X, "y": $NEXT_Y, "width": 3, "height": 3, "properties": { "markdown": "### $title\\n# $count" } }
EOF
)"
  NEXT_SUMMARY_X=$((NEXT_SUMMARY_X + 3))
}

append_logo_widget() {
  local x="$1"
  local y="$2"
  local width="$3"
  local height="$4"

  append_widget "$(cat <<EOF
    { "type": "text", "x": $x, "y": $y, "width": $width, "height": $height, "properties": { "markdown": "![ABS Logo]($LOGO_URL)" } }
EOF
)"
}

append_count_card() {
  local x="$1"
  local y="$2"
  local width="$3"
  local height="$4"
  local title="$5"
  local count="$6"

  append_widget "$(cat <<EOF
    { "type": "text", "x": $x, "y": $y, "width": $width, "height": $height, "properties": { "markdown": "## $title\\n# $count" } }
EOF
)"
}

append_resource_count_cards() {
  local card_index=0
  local card_x
  local card_y

  append_resource_count_card() {
    local title="$1"
    local count="$2"

    if [ "$count" -le 0 ]; then
      return
    fi

    card_x=$((5 + (card_index % 2) * 2))
    card_y=$((NEXT_Y + (card_index / 2) * 3))
    append_count_card "$card_x" "$card_y" 2 3 "$title" "$count"
    card_index=$((card_index + 1))
  }

  append_resource_count_card "EC2" "$EC2_TOTAL_COUNT"
  append_resource_count_card "EBS Volumes" "$EBS_TOTAL_COUNT"
  append_resource_count_card "RDS" "$RDS_DB_COUNT"
  append_resource_count_card "FSx" "$FSX_FILE_SYSTEM_COUNT"
}

append_section_header() {
  local title="$1"
  local marker="${2:-🔵}"
  append_widget "$(cat <<EOF
    { "type": "text", "x": 0, "y": $NEXT_Y, "width": 24, "height": 1, "properties": { "markdown": "## $marker $title", "background": "solid" } }
EOF
)"
  NEXT_Y=$((NEXT_Y + 1))
}

append_logs_placeholder() {
  append_widget "$(cat <<EOF
    { "type": "text", "x": 0, "y": $NEXT_Y, "width": 24, "height": 3, "properties": { "markdown": "## Customer Logs\\n\\nReserved area for customer-specific CloudWatch Logs Insights widgets. Add log group widgets here." } }
EOF
)"
  NEXT_Y=$((NEXT_Y + 3))
}

append_metric_widget() {
  local x="$1"
  local y="$2"
  local width="$3"
  local height="$4"
  local title="$5"
  local metrics="$6"
  local stat="$7"
  local view="$8"
  local extra_properties="${9:-}"

  if [ -n "$extra_properties" ]; then
    extra_properties=",$extra_properties"
  fi

  append_widget "$(cat <<EOF
    { "type": "metric", "x": $x, "y": $y, "width": $width, "height": $height, "properties": { "metrics": $metrics, "period": 300, "stat": "$stat", "region": "$REGION", "title": "$title", "view": "$view"$extra_properties } }
EOF
)"
}

append_two_metric_widgets() {
  local title_left="$1"
  local metrics_left="$2"
  local stat_left="$3"
  local view_left="$4"
  local extra_left="$5"
  local title_right="$6"
  local metrics_right="$7"
  local stat_right="$8"
  local view_right="$9"
  local extra_right="${10:-}"

  append_metric_widget 0 "$NEXT_Y" 12 6 "$title_left" "$metrics_left" "$stat_left" "$view_left" "$extra_left"
  append_metric_widget 12 "$NEXT_Y" 12 6 "$title_right" "$metrics_right" "$stat_right" "$view_right" "$extra_right"
  NEXT_Y=$((NEXT_Y + 6))
}

UTILIZATION_AXIS='"yAxis": { "left": { "min": 0, "max": 100 } }'
CPU_ANNOTATIONS='"annotations": { "horizontal": [ { "value": 90, "label": "P1 Critical - (90)", "color": "#d62728" }, { "value": 80, "label": "P2 Warning - (80)", "color": "#ff7f0e" } ] }'
MEMORY_DISK_ANNOTATIONS='"annotations": { "horizontal": [ { "value": 90, "label": "P1 Critical - (90)", "color": "#d62728" }, { "value": 85, "label": "P2 Warning - (85)", "color": "#ff7f0e" } ] }'
STATUS_ANNOTATIONS='"annotations": { "horizontal": [ { "value": 1, "label": "P1 Critical - (1)", "color": "#d62728" } ] }'
ERROR_ANNOTATIONS='"annotations": { "horizontal": [ { "value": 1, "label": "P2 Warning - (1)", "color": "#ff7f0e" } ] }'
THROTTLE_ANNOTATIONS='"annotations": { "horizontal": [ { "value": 1, "label": "P2 Warning - (1)", "color": "#ff7f0e" } ] }'
ALB_LATENCY_AXIS='"yAxis": { "left": { "min": 0, "max": 2 } }'
ALB_4XX_ANNOTATIONS='"annotations": { "horizontal": [ { "value": 10, "label": "P2 Warning - (10)", "color": "#ff7f0e" } ] }'
ALB_ERROR_ANNOTATIONS='"annotations": { "horizontal": [ { "value": 5, "label": "P1 Critical - (5)", "color": "#d62728" }, { "value": 1, "label": "P2 Warning - (1)", "color": "#ff7f0e" } ] }'
ALB_UNHEALTHY_HOST_ANNOTATIONS='"annotations": { "horizontal": [ { "value": 1, "label": "P1 Critical - (1)", "color": "#d62728" } ] }'
EBS_STALLED_IO_ANNOTATIONS='"annotations": { "horizontal": [ { "value": 1, "label": "P1 Critical - (1)", "color": "#d62728" } ] }'
BACKUP_FAILED_ANNOTATIONS='"annotations": { "horizontal": [ { "value": 1, "label": "P1 Critical - (1)", "color": "#d62728" } ] }'
EFS_IO_LIMIT_ANNOTATIONS='"annotations": { "horizontal": [ { "value": 90, "label": "P1 Critical - (90)", "color": "#d62728" }, { "value": 80, "label": "P2 Warning - (80)", "color": "#ff7f0e" } ] }'

if [ "$EC2_INSTANCE_METRIC_COUNT" -gt 0 ]; then
  echo "Adding EC2 widgets..."
  append_section_header "EC2 Compute" "🔴"
  append_logo_widget 0 "$NEXT_Y" 5 6
  append_resource_count_cards
  append_metric_widget 9 "$NEXT_Y" 4 6 "EC2 Status Check Failed" "$(metric_array "$EC2_STATUS_METRICS")" "Maximum" "timeSeries" "$STATUS_ANNOTATIONS"
  append_metric_widget 13 "$NEXT_Y" 4 6 "EC2 State Distribution" "$EC2_STATE_METRICS" "Average" "bar" ""
  append_metric_widget 17 "$NEXT_Y" 7 6 "EC2 CPU Utilization" "$(metric_array "$EC2_CPU_METRICS")" "Average" "timeSeries" "$CPU_ANNOTATIONS,$UTILIZATION_AXIS"
  NEXT_Y=$((NEXT_Y + 6))

  if [ "$EBS_ATTACHED_METRIC_COUNT" -gt 0 ]; then
    append_metric_widget 0 "$NEXT_Y" 7 6 "EC2 Network In / Out" "$(metric_array "$EC2_NETWORK_METRICS")" "Average" "timeSeries" ""
    append_metric_widget 7 "$NEXT_Y" 8 6 "EC2 Memory Used %" "$EC2_MEMORY_METRICS" "Average" "gauge" "$MEMORY_DISK_ANNOTATIONS,$UTILIZATION_AXIS"
    append_metric_widget 15 "$NEXT_Y" 4 6 "EBS Read Ops" "$(metric_array "$EBS_READ_OPS_METRICS")" "Sum" "bar" ""
    append_metric_widget 19 "$NEXT_Y" 5 6 "EBS Write Ops" "$(metric_array "$EBS_WRITE_OPS_METRICS")" "Sum" "bar" ""
  else
    append_metric_widget 0 "$NEXT_Y" 12 6 "EC2 Network In / Out" "$(metric_array "$EC2_NETWORK_METRICS")" "Average" "timeSeries" ""
    append_metric_widget 12 "$NEXT_Y" 12 6 "EC2 Memory Used %" "$EC2_MEMORY_METRICS" "Average" "gauge" "$MEMORY_DISK_ANNOTATIONS,$UTILIZATION_AXIS"
  fi
  NEXT_Y=$((NEXT_Y + 6))

  if [ "$(echo "$EC2_MEMORY_AVAILABLE_METRICS" | jq 'length')" -gt 0 ] && [ "$(echo "$EC2_MEMORY_AVAILABLE_PERCENT_METRICS" | jq 'length')" -gt 0 ]; then
    append_metric_widget 0 "$NEXT_Y" 12 6 "EC2 Memory Available" "$EC2_MEMORY_AVAILABLE_METRICS" "Average" "timeSeries" ""
    append_metric_widget 12 "$NEXT_Y" 12 6 "EC2 Memory Available %" "$EC2_MEMORY_AVAILABLE_PERCENT_METRICS" "Average" "gauge" "$UTILIZATION_AXIS"
    NEXT_Y=$((NEXT_Y + 6))
  elif [ "$(echo "$EC2_MEMORY_AVAILABLE_METRICS" | jq 'length')" -gt 0 ]; then
    append_metric_widget 0 "$NEXT_Y" 24 6 "EC2 Memory Available" "$EC2_MEMORY_AVAILABLE_METRICS" "Average" "timeSeries" ""
    NEXT_Y=$((NEXT_Y + 6))
  elif [ "$(echo "$EC2_MEMORY_AVAILABLE_PERCENT_METRICS" | jq 'length')" -gt 0 ]; then
    append_metric_widget 0 "$NEXT_Y" 24 6 "EC2 Memory Available %" "$EC2_MEMORY_AVAILABLE_PERCENT_METRICS" "Average" "gauge" "$UTILIZATION_AXIS"
    NEXT_Y=$((NEXT_Y + 6))
  fi

  if [ "$(echo "$EC2_WINDOWS_MEMORY_USED_PERCENT_METRICS" | jq 'length')" -gt 0 ] && [ "$(echo "$EC2_WINDOWS_MEMORY_AVAILABLE_MB_METRICS" | jq 'length')" -gt 0 ]; then
    append_metric_widget 0 "$NEXT_Y" 12 6 "EC2 Windows Memory Used %" "$EC2_WINDOWS_MEMORY_USED_PERCENT_METRICS" "Average" "gauge" "$MEMORY_DISK_ANNOTATIONS,$UTILIZATION_AXIS"
    append_metric_widget 12 "$NEXT_Y" 12 6 "EC2 Windows Memory Available MB" "$EC2_WINDOWS_MEMORY_AVAILABLE_MB_METRICS" "Average" "timeSeries" ""
    NEXT_Y=$((NEXT_Y + 6))
  elif [ "$(echo "$EC2_WINDOWS_MEMORY_USED_PERCENT_METRICS" | jq 'length')" -gt 0 ]; then
    append_metric_widget 0 "$NEXT_Y" 24 6 "EC2 Windows Memory Used %" "$EC2_WINDOWS_MEMORY_USED_PERCENT_METRICS" "Average" "gauge" "$MEMORY_DISK_ANNOTATIONS,$UTILIZATION_AXIS"
    NEXT_Y=$((NEXT_Y + 6))
  elif [ "$(echo "$EC2_WINDOWS_MEMORY_AVAILABLE_MB_METRICS" | jq 'length')" -gt 0 ]; then
    append_metric_widget 0 "$NEXT_Y" 24 6 "EC2 Windows Memory Available MB" "$EC2_WINDOWS_MEMORY_AVAILABLE_MB_METRICS" "Average" "timeSeries" ""
    NEXT_Y=$((NEXT_Y + 6))
  fi

  if [ "$(echo "$EC2_DISK_METRICS" | jq 'length')" -gt 0 ]; then
    append_metric_widget 0 "$NEXT_Y" 24 6 "EC2 Disk Used %" "$EC2_DISK_METRICS" "Average" "gauge" "$MEMORY_DISK_ANNOTATIONS,$UTILIZATION_AXIS"
    NEXT_Y=$((NEXT_Y + 6))
  fi

  if [ "$(echo "$EC2_WINDOWS_DISK_USED_PERCENT_METRICS" | jq 'length')" -gt 0 ]; then
    append_metric_widget 0 "$NEXT_Y" 12 6 "EC2 Windows Disk Used %" "$EC2_WINDOWS_DISK_USED_PERCENT_METRICS" "Average" "gauge" "$MEMORY_DISK_ANNOTATIONS,$UTILIZATION_AXIS"
    append_metric_widget 12 "$NEXT_Y" 12 6 "EC2 Windows Disk Free %" "$EC2_WINDOWS_DISK_FREE_PERCENT_METRICS" "Average" "gauge" "$UTILIZATION_AXIS"
    NEXT_Y=$((NEXT_Y + 6))
  elif [ "$(echo "$EC2_WINDOWS_DISK_FREE_PERCENT_METRICS" | jq 'length')" -gt 0 ]; then
    append_metric_widget 0 "$NEXT_Y" 24 6 "EC2 Windows Disk Free %" "$EC2_WINDOWS_DISK_FREE_PERCENT_METRICS" "Average" "gauge" "$UTILIZATION_AXIS"
    NEXT_Y=$((NEXT_Y + 6))
  fi

  if [ "$(echo "$EC2_WINDOWS_DISK_FREE_MB_METRICS" | jq 'length')" -gt 0 ]; then
    append_metric_widget 0 "$NEXT_Y" 24 6 "EC2 Windows Disk Free MB" "$EC2_WINDOWS_DISK_FREE_MB_METRICS" "Average" "timeSeries" ""
    NEXT_Y=$((NEXT_Y + 6))
  fi

  if [ "$(echo "$EC2_DISK_USED_METRICS" | jq 'length')" -gt 0 ] && [ "$(echo "$EC2_DISK_FREE_METRICS" | jq 'length')" -gt 0 ]; then
    append_metric_widget 0 "$NEXT_Y" 8 6 "EC2 Disk Used" "$EC2_DISK_USED_METRICS" "Average" "timeSeries" ""
    append_metric_widget 8 "$NEXT_Y" 8 6 "EC2 Disk Free" "$EC2_DISK_FREE_METRICS" "Average" "timeSeries" ""
    if [ "$(echo "$EC2_DISK_TOTAL_METRICS" | jq 'length')" -gt 0 ]; then
      append_metric_widget 16 "$NEXT_Y" 8 6 "EC2 Disk Total" "$EC2_DISK_TOTAL_METRICS" "Average" "timeSeries" ""
    fi
    NEXT_Y=$((NEXT_Y + 6))
  elif [ "$(echo "$EC2_DISK_USED_METRICS" | jq 'length')" -gt 0 ]; then
    append_metric_widget 0 "$NEXT_Y" 12 6 "EC2 Disk Used" "$EC2_DISK_USED_METRICS" "Average" "timeSeries" ""
    if [ "$(echo "$EC2_DISK_TOTAL_METRICS" | jq 'length')" -gt 0 ]; then
      append_metric_widget 12 "$NEXT_Y" 12 6 "EC2 Disk Total" "$EC2_DISK_TOTAL_METRICS" "Average" "timeSeries" ""
    fi
    NEXT_Y=$((NEXT_Y + 6))
  elif [ "$(echo "$EC2_DISK_FREE_METRICS" | jq 'length')" -gt 0 ]; then
    append_metric_widget 0 "$NEXT_Y" 12 6 "EC2 Disk Free" "$EC2_DISK_FREE_METRICS" "Average" "timeSeries" ""
    if [ "$(echo "$EC2_DISK_TOTAL_METRICS" | jq 'length')" -gt 0 ]; then
      append_metric_widget 12 "$NEXT_Y" 12 6 "EC2 Disk Total" "$EC2_DISK_TOTAL_METRICS" "Average" "timeSeries" ""
    fi
    NEXT_Y=$((NEXT_Y + 6))
  elif [ "$(echo "$EC2_DISK_TOTAL_METRICS" | jq 'length')" -gt 0 ]; then
    append_metric_widget 0 "$NEXT_Y" 24 6 "EC2 Disk Total" "$EC2_DISK_TOTAL_METRICS" "Average" "timeSeries" ""
    NEXT_Y=$((NEXT_Y + 6))
  fi
else
  echo "Skipping EC2 widgets because no running or stopped EC2 instances were found."
fi

if [ "$EBS_TOTAL_COUNT" -gt 0 ]; then
  echo "Adding EBS widgets..."
  append_section_header "EBS Volumes" "⚫"

  if [ "$EBS_ATTACHED_METRIC_COUNT" -gt 0 ]; then
    append_metric_widget 0 "$NEXT_Y" 8 6 "EBS State Distribution" "$EBS_STATE_METRICS" "Average" "bar" ""
    append_metric_widget 8 "$NEXT_Y" 8 6 "EBS Read Bytes" "$(metric_array "$EBS_READ_BYTES_METRICS")" "Sum" "timeSeries" ""
    append_metric_widget 16 "$NEXT_Y" 8 6 "EBS Write Bytes" "$(metric_array "$EBS_WRITE_BYTES_METRICS")" "Sum" "timeSeries" ""
    NEXT_Y=$((NEXT_Y + 6))
    append_metric_widget 0 "$NEXT_Y" 24 6 "EBS Stalled I/O Check" "$(metric_array "$EBS_STALLED_IO_METRICS")" "Maximum" "timeSeries" "$EBS_STALLED_IO_ANNOTATIONS"
    NEXT_Y=$((NEXT_Y + 6))
  else
    append_metric_widget 0 "$NEXT_Y" 24 6 "EBS State Distribution" "$EBS_STATE_METRICS" "Average" "bar" ""
    NEXT_Y=$((NEXT_Y + 6))
  fi
else
  echo "Skipping EBS widgets because no EBS volumes were found."
fi

if [ "$EFS_FILE_SYSTEM_COUNT" -gt 0 ]; then
  echo "Adding EFS widgets..."
  append_section_header "EFS File Systems" "🟢"
  append_metric_widget 0 "$NEXT_Y" 8 6 "EFS Read Bytes" "$(metric_array "$EFS_READ_BYTES_METRICS")" "Sum" "timeSeries" ""
  append_metric_widget 8 "$NEXT_Y" 8 6 "EFS Write Bytes" "$(metric_array "$EFS_WRITE_BYTES_METRICS")" "Sum" "timeSeries" ""
  append_metric_widget 16 "$NEXT_Y" 8 6 "EFS Percent IO Limit" "$(metric_array "$EFS_PERCENT_IO_METRICS")" "Average" "gauge" "$EFS_IO_LIMIT_ANNOTATIONS,$UTILIZATION_AXIS"
  NEXT_Y=$((NEXT_Y + 6))
  append_metric_widget 0 "$NEXT_Y" 8 6 "EFS Total IO Bytes" "$(metric_array "$EFS_TOTAL_IO_METRICS")" "Sum" "bar" ""
  append_metric_widget 8 "$NEXT_Y" 8 6 "EFS Client Connections" "$(metric_array "$EFS_CLIENT_CONNECTION_METRICS")" "Sum" "timeSeries" ""
  append_metric_widget 16 "$NEXT_Y" 8 6 "EFS Burst Credit Balance" "$(metric_array "$EFS_BURST_CREDIT_METRICS")" "Average" "timeSeries" ""
  NEXT_Y=$((NEXT_Y + 6))
else
  echo "Skipping EFS widgets because no EFS file systems were found."
fi

if [ "$FSX_FILE_SYSTEM_COUNT" -gt 0 ]; then
  echo "Adding FSx widgets..."
  append_section_header "FSx File Systems" "🟢"
  append_metric_widget 0 "$NEXT_Y" 8 6 "FSx Read Bytes" "$(metric_array "$FSX_READ_BYTES_METRICS")" "Sum" "timeSeries" ""
  append_metric_widget 8 "$NEXT_Y" 8 6 "FSx Write Bytes" "$(metric_array "$FSX_WRITE_BYTES_METRICS")" "Sum" "timeSeries" ""
  append_metric_widget 16 "$NEXT_Y" 8 6 "FSx Free Storage" "$(metric_array "$FSX_FREE_STORAGE_METRICS")" "Average" "singleValue" ""
  NEXT_Y=$((NEXT_Y + 6))
  append_two_metric_widgets "FSx Read Operations" "$(metric_array "$FSX_READ_OPS_METRICS")" "Sum" "bar" "" "FSx Write Operations" "$(metric_array "$FSX_WRITE_OPS_METRICS")" "Sum" "bar" ""
else
  echo "Skipping FSx widgets because no FSx file systems were found."
fi

if [ "$ECS_SERVICE_COUNT" -gt 0 ]; then
  echo "Adding ECS widgets..."
  append_section_header "ECS Services" "🔵"
  append_metric_widget 0 "$NEXT_Y" 8 6 "ECS Resource Summary" "$ECS_SUMMARY_METRICS" "Average" "bar" ""
  append_metric_widget 8 "$NEXT_Y" 8 6 "ECS CPU Utilization" "$(metric_array "$ECS_CPU_METRICS")" "Average" "gauge" "$CPU_ANNOTATIONS,$UTILIZATION_AXIS"
  append_metric_widget 16 "$NEXT_Y" 8 6 "ECS Memory Utilization" "$(metric_array "$ECS_MEMORY_METRICS")" "Average" "gauge" "$MEMORY_DISK_ANNOTATIONS,$UTILIZATION_AXIS"
  NEXT_Y=$((NEXT_Y + 6))
  append_two_metric_widgets "ECS Running Task Count" "$(metric_array "$ECS_RUNNING_TASK_METRICS")" "Average" "bar" "" "ECS Pending Task Count" "$(metric_array "$ECS_PENDING_TASK_METRICS")" "Average" "bar" ""
else
  echo "Skipping ECS widgets because no ECS services were found."
fi

if [ "$EKS_CLUSTER_COUNT" -gt 0 ]; then
  echo "Adding EKS widgets..."
  append_section_header "EKS Clusters" "🟣"
  append_metric_widget 0 "$NEXT_Y" 8 6 "EKS Node Summary" "$EKS_SUMMARY_METRICS" "Average" "bar" ""
  append_metric_widget 8 "$NEXT_Y" 8 6 "EKS Node CPU Utilization" "$(metric_array "$EKS_CPU_METRICS")" "Average" "gauge" "$CPU_ANNOTATIONS,$UTILIZATION_AXIS"
  append_metric_widget 16 "$NEXT_Y" 8 6 "EKS Node Memory Utilization" "$(metric_array "$EKS_MEMORY_METRICS")" "Average" "gauge" "$MEMORY_DISK_ANNOTATIONS,$UTILIZATION_AXIS"
  NEXT_Y=$((NEXT_Y + 6))
  append_two_metric_widgets "EKS Node Filesystem Utilization" "$(metric_array "$EKS_FILESYSTEM_METRICS")" "Average" "gauge" "$MEMORY_DISK_ANNOTATIONS,$UTILIZATION_AXIS" "EKS Running Pods" "$(metric_array "$EKS_POD_METRICS")" "Average" "timeSeries" ""
else
  echo "Skipping EKS widgets because no EKS clusters were found."
fi

if [ "$ALB_COUNT" -gt 0 ]; then
  echo "Adding Application Load Balancer widgets..."
  append_section_header "Application Load Balancers" "🟠"
  append_metric_widget 0 "$NEXT_Y" 8 6 "ALB Request Share" "$(metric_array "$ALB_REQUEST_METRICS")" "Sum" "pie" ""
  append_metric_widget 8 "$NEXT_Y" 8 6 "ALB Target Response Time" "$(metric_array "$ALB_RESPONSE_TIME_METRICS")" "Average" "gauge" "$ALB_LATENCY_AXIS"
  append_metric_widget 16 "$NEXT_Y" 8 6 "ALB 5XX Errors" "$(metric_array "$ALB_5XX_METRICS")" "Sum" "timeSeries" "$ALB_ERROR_ANNOTATIONS"
  NEXT_Y=$((NEXT_Y + 6))

  if [ "$TARGET_GROUP_COUNT" -gt 0 ]; then
    append_metric_widget 0 "$NEXT_Y" 8 6 "ALB 4XX Errors" "$(metric_array "$ALB_4XX_METRICS")" "Sum" "timeSeries" "$ALB_4XX_ANNOTATIONS"
    append_metric_widget 8 "$NEXT_Y" 8 6 "ALB Healthy Host Count" "$(metric_array "$ALB_HEALTHY_HOST_METRICS")" "Average" "timeSeries" ""
    append_metric_widget 16 "$NEXT_Y" 8 6 "ALB Unhealthy Host Count" "$(metric_array "$ALB_UNHEALTHY_HOST_METRICS")" "Maximum" "timeSeries" "$ALB_UNHEALTHY_HOST_ANNOTATIONS"
    NEXT_Y=$((NEXT_Y + 6))
  else
    append_metric_widget 0 "$NEXT_Y" 24 6 "ALB 4XX Errors" "$(metric_array "$ALB_4XX_METRICS")" "Sum" "timeSeries" "$ALB_4XX_ANNOTATIONS"
    NEXT_Y=$((NEXT_Y + 6))
  fi
else
  echo "Skipping Application Load Balancer widgets because no Application Load Balancers were found."
fi

if [ "$LAMBDA_FUNCTION_COUNT" -gt 0 ]; then
  echo "Adding Lambda widgets..."
  append_section_header "Lambda Functions" "🟡"
  append_metric_widget 0 "$NEXT_Y" 8 6 "Lambda Invocation Share" "$(metric_array "$LAMBDA_INVOCATIONS_METRICS")" "Sum" "pie" ""
  append_metric_widget 8 "$NEXT_Y" 8 6 "Lambda Invocations" "$(metric_array "$LAMBDA_INVOCATIONS_METRICS")" "Sum" "bar" ""
  append_metric_widget 16 "$NEXT_Y" 8 6 "Lambda Errors" "$(metric_array "$LAMBDA_ERRORS_METRICS")" "Sum" "timeSeries" "$ERROR_ANNOTATIONS"
  NEXT_Y=$((NEXT_Y + 6))
  append_two_metric_widgets "Lambda Duration Avg (ms)" "$(metric_array "$LAMBDA_DURATION_METRICS")" "Average" "timeSeries" "" "Lambda Throttles" "$(metric_array "$LAMBDA_THROTTLES_METRICS")" "Sum" "timeSeries" "$THROTTLE_ANNOTATIONS"
else
  echo "Skipping Lambda widgets because no Lambda functions were found."
fi

if [ "$RDS_DB_COUNT" -gt 0 ]; then
  echo "Adding RDS widgets..."
  append_section_header "RDS Databases" "🟢"
  append_two_metric_widgets "RDS CPU Utilization" "$(metric_array "$RDS_CPU_METRICS")" "Average" "gauge" "$CPU_ANNOTATIONS,$UTILIZATION_AXIS" "RDS Free Storage" "$(metric_array "$RDS_STORAGE_METRICS")" "Average" "timeSeries" ""
  append_two_metric_widgets "RDS Read / Write Latency" "$(metric_array "$RDS_LATENCY_METRICS")" "Average" "timeSeries" "" "RDS Connections" "$(metric_array "$RDS_CONN_METRICS")" "Average" "timeSeries" ""
else
  echo "Skipping RDS widgets because no RDS DB instances were found."
fi

if [ "$BACKUP_METRIC_COUNT" -gt 0 ]; then
  echo "Adding AWS Backup widgets..."
  append_section_header "AWS Backup Jobs" "⚫"

  if [ "$BACKUP_COMPLETED_METRIC_COUNT" -gt 0 ] && [ "$BACKUP_FAILED_METRIC_COUNT" -gt 0 ]; then
    append_two_metric_widgets "Backup Jobs Completed" "$BACKUP_COMPLETED_METRICS" "Sum" "bar" "" "Backup Jobs Failed" "$BACKUP_FAILED_METRICS" "Sum" "timeSeries" "$BACKUP_FAILED_ANNOTATIONS"
  elif [ "$BACKUP_COMPLETED_METRIC_COUNT" -gt 0 ]; then
    append_metric_widget 0 "$NEXT_Y" 24 6 "Backup Jobs Completed" "$BACKUP_COMPLETED_METRICS" "Sum" "bar" ""
    NEXT_Y=$((NEXT_Y + 6))
  else
    append_metric_widget 0 "$NEXT_Y" 24 6 "Backup Jobs Failed" "$BACKUP_FAILED_METRICS" "Sum" "timeSeries" "$BACKUP_FAILED_ANNOTATIONS"
    NEXT_Y=$((NEXT_Y + 6))
  fi
else
  echo "Skipping AWS Backup widgets because no AWS Backup CloudWatch job metrics were found."
fi

append_logs_placeholder

DASHBOARD_BODY=$(cat <<EOF
{
  "widgets": [
$WIDGETS
  ]
}
EOF
)

echo "$DASHBOARD_BODY" | jq . >/dev/null

aws cloudwatch put-dashboard \
  --region "$REGION" \
  --dashboard-name "$DASHBOARD_NAME" \
  --dashboard-body "$DASHBOARD_BODY"

echo "Combined AWS dashboard created/updated: $DASHBOARD_NAME"
