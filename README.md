# CloudWatch Dashboard and Alarm Scripts

Scripts to create an AWS CloudWatch infrastructure dashboard and CloudWatch alarms for common AWS resources.

## Files

- `ALL.sh` creates or updates a compact CloudWatch dashboard.
- `ALARMS.sh` creates or updates CloudWatch alarms and sends alarm actions to an SNS topic.

## Requirements

- AWS CLI configured with access to the target account.
- `jq` installed.
- Permissions for CloudWatch, EC2, RDS, EBS, EFS, Lambda, ELBv2, Backup, and SNS as needed.

## Create Dashboard

```bash
REGION="eu-west-1" \
DASHBOARD_NAME="AWS-Compact-Monitoring" \
CUSTOMER_NAME="Al Baraka - Sudan" \
LOGO_URL="https://images.seeklogo.com/logo-png/49/1/al-baraka-bank-logo-png_seeklogo-496466.png" \
bash ALL.sh
```

`ALL.sh` discovers available resources and adds widgets only when matching resources or metrics exist. CloudWatch Agent memory and disk metrics are deduplicated so repeated dimension variants do not create confusing duplicate dashboard entries.

## Create Alarms

```bash
REGION="eu-west-1" \
TOPIC_ARN="arn:aws:sns:eu-west-1:334361471548:EDB-AWS-Infra-Alerts" \
ALARM_PREFIX="aws-infra-monitoring" \
bash ALARMS.sh
```

Optional ALB 4xx threshold override:

```bash
ALB_4XX_THRESHOLD=500 bash ALARMS.sh
```

## Notes

- Existing CloudWatch alarms with old duplicate names are not deleted automatically.
- CloudWatch Agent must be installed and publishing metrics for EC2 memory and disk widgets or alarms.
- Windows metrics are supported when the CloudWatch Agent publishes Windows performance counter metrics.
