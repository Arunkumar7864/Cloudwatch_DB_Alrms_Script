# CloudWatch Dashboard and Alarm Scripts

Use these scripts from AWS CloudShell to create a CloudWatch infrastructure dashboard and CloudWatch alarms.

## Files

- `ALL.sh` creates or updates the CloudWatch dashboard.
- `ALARMS.sh` creates or updates CloudWatch alarms and sends notifications to an SNS topic.

## CloudShell Requirements

AWS CloudShell already includes the AWS CLI. Check `jq` before running:

```bash
jq --version
```

If `jq` is missing, install it in CloudShell:

```bash
sudo yum install -y jq
```

Your CloudShell session must be opened in the AWS account where you want to create the dashboard and alarms. The IAM user or role must have permissions for CloudWatch, EC2, RDS, EBS, EFS, Lambda, ELBv2, AWS Backup, and SNS.

## Clone The Repository

```bash
git clone https://github.com/Arunkumar7864/Cloudwatch_DB_Alrms_Script.git
cd Cloudwatch_DB_Alrms_Script
chmod +x ALL.sh ALARMS.sh
```

## Create The Dashboard

Edit the company name in `ALL.sh` if needed:

```bash
CUSTOMER_NAME="${CUSTOMER_NAME:-company_name}"
```

Run from CloudShell:

```bash
REGION="eu-west-1" \
DASHBOARD_NAME="AWS-Compact-Monitoring" \
CUSTOMER_NAME="company_name" \
LOGO_URL="https://example.com/company-logo.png" \
bash ALL.sh
```

`LOGO_URL` is optional. If you use it, the dashboard renders it in this format:

```markdown
![ABS Logo](https://example.com/company-logo.png)
```

## Create The Alarms

Create or identify an SNS topic first, then use its ARN. Do not leave the example ARN as-is.

Example ARN format:

```text
arn:aws:sns:REGION:ACCOUNT_ID:TOPIC_NAME
```

Run from CloudShell:

```bash
REGION="eu-west-1" \
TOPIC_ARN="arn:aws:sns:eu-west-1:123456789012:infra-alerts" \
ALARM_PREFIX="aws-infra-monitoring" \
bash ALARMS.sh
```

Optional ALB 4xx threshold override:

```bash
ALB_4XX_THRESHOLD=500 \
REGION="eu-west-1" \
TOPIC_ARN="arn:aws:sns:eu-west-1:123456789012:infra-alerts" \
bash ALARMS.sh
```

## Notes

- `TOPIC_ARN` is required for `ALARMS.sh`; the script does not include a real customer SNS topic by default.
- Existing CloudWatch alarms with older duplicate names are not deleted automatically.
- CloudWatch Agent must be installed and publishing metrics for EC2 memory and disk widgets or alarms.
- Windows metrics are supported when the CloudWatch Agent publishes Windows performance counter metrics.
- Dashboard memory and disk widgets deduplicate repeated CloudWatch Agent dimension variants.
