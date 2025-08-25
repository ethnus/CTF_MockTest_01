# Ethnus AWS Mock Test Project

[![AWS](https://img.shields.io/badge/AWS-Cloud-orange)](https://aws.amazon.com/)
[![Terraform](https://img.shields.io/badge/Terraform-Infrastructure-blue)](https://terraform.io/)
[![Difficulty](https://img.shields.io/badge/Difficulty-Intermediate-yellow)](https://github.com)

A comprehensive AWS serverless architecture challenge designed to test cloud engineering skills in a CTF (Capture The Flag)-type environment.

## 🎯 Overview

This challenge simulates a real-world AWS environment where you'll need to implement, secure, and troubleshoot a serverless architecture while working within the constraints of AWS Academy Learner Lab. You'll diagnose misconfigurations, apply security best practices, and demonstrate proficiency in cloud-native application development.

## 🏗️ Architecture

The project implements a multi-VPC serverless architecture with the following components:

```
┌─────────────────┐    ┌──────────────────────────────┐
│   VPC A (App)   │    │      Other AWS Services      │
│                 │    │                              │
│  ┌─────────────┐│    │ ┌─────────┐ ┌──────────────┐ │
│  │ API Gateway ││────│ │   S3    │ │  DynamoDB    │ │
│  │ (Private)   ││    │ │ (KMS)   │ │  (KMS)       │ │
│  └─────────────┘│    │ └─────────┘ └──────────────┘ │
│                 │    │                              │
│  ┌─────────────┐│    │ ┌─────────┐ ┌──────────────┐ │
│  │   Lambda    ││────│ │   SNS   │ │ EventBridge  │ │
│  │   Reader    ││    │ │ Topic   │ │    Rule      │ │
│  └─────────────┘│    │ └─────────┘ └──────────────┘ │
│                 │    │                              │
│  ┌─────────────┐│    │ ┌─────────┐                  │
│  │   Lambda    ││────│ │   KMS   │                  │
│  │   Writer    ││    │ │   Key   │                  │
│  └─────────────┘│    │ └─────────┘                  │
└─────────────────┘    └──────────────────────────────┘
         │
    VPC Peering
         │
┌─────────────────┐
│   VPC B (Peer)  │
│                 │
│ Other Internal  │
│    Systems      │
└─────────────────┘
```

## 📋 Prerequisites

### Required Access
- **AWS Academy Learner Lab** account with active session
- Access to AWS CLI (configured with Learner Lab credentials)
- Basic understanding of AWS services

### Required Tools
- **Terraform** >= 1.5.0 (auto-installed by deploy script)
- **AWS CLI** >= 2.0
- **jq** (for evaluation script)
- **bash** (for running scripts)

### Required Knowledge
- AWS fundamentals (VPC, Lambda, S3, DynamoDB, IAM)
- Basic Terraform concepts
- JSON/YAML configuration
- Command line proficiency

## 🚀 Quick Start

### For Students (Challenge Takers)

1. **Setup Workspace (AWS CloudShell)**
   ```bash
   # Create workspace directory with sufficient storage
   sudo mkdir -p /workspace
   sudo chown cloudshell-user:cloudshell-user /workspace
   cd /workspace
   ```

2. **Clone Repository and Navigate**
   ```bash
   # Clone the challenge repository
   git clone https://github.com/ethnus/CTF_MockTest_01.git
   cd CTF_MockTest_01/scripts/
   ```

3. **Deploy Infrastructure**
   ```bash
   # Set your preferences (optional)
   export PREFIX="ethnus-mocktest-01"
   export REGION="us-east-1"
   
   # Deploy the challenge environment
   bash deploy.sh
   ```

   **Quick One-Liner:**
   ```bash
   sudo mkdir -p /workspace && sudo chown cloudshell-user:cloudshell-user /workspace && cd /workspace && git clone https://github.com/ethnus/CTF_MockTest_01.git && cd CTF_MockTest_01/scripts/ && bash deploy.sh && bash eval.sh
   ```

4. **Run Initial Evaluation**
   ```bash
   bash eval.sh
   ```
   You should see multiple `INCOMPLETE` status items - these are your challenges!

5. **Start Troubleshooting**
   - Use AWS Console, CLI, and documentation
   - Fix configurations one by one
   - Re-run `bash eval.sh` to check progress

6. **Complete the Challenge**
   - All 12 checks should show `ACCEPTED`
   - The final flag will be revealed

### For Instructors (Challenge Administrators)

1. **Setup and Deploy Student Environment**
   ```bash
   # Setup workspace directory (AWS CloudShell)
   sudo mkdir -p /workspace
   sudo chown cloudshell-user:cloudshell-user /workspace
   cd /workspace
   
   # Clone the challenge repository
   git clone https://github.com/ethnus/CTF_MockTest_01.git
   cd CTF_MockTest_01/scripts/
   
   # Deploy the infrastructure
   bash deploy.sh
   ```

2. **Verify Challenge State**
   ```bash
   bash eval.sh
   # Should show intentional misconfigurations
   ```

3. **Monitor Student Progress**
   Students can run `eval.sh` anytime to check their progress

4. **Provide Hints** (if needed)
   Each challenge has specific learning objectives (see Challenge Details below)

5. **Reset Environment** (if needed)
   ```bash
   # Fix all issues for demonstration
   bash remediate.sh
   
   # Completely clean up
   bash teardown.sh
   ```

## 📊 Challenge Structure

The evaluation script tests **12 key areas** of cloud architecture and security:

| # | Challenge | Focus Area | Learning Objective |
|---|-----------|------------|-------------------|
| 1 | Tags: object storage | Resource Management | Proper S3 bucket tagging |
| 2 | Tags: key-value database | Resource Management | DynamoDB tagging compliance |
| 3 | Compute concurrency | Performance | Lambda concurrency limits |
| 4 | Compute configuration | Application Config | Environment variables |
| 5 | Notifications publish | Messaging | SNS permissions |
| 6 | Private data endpoint policy | Network Security | VPC endpoint policies |
| 7 | Network endpoints routing | Network Architecture | Route table associations |
| 8 | API integration | Service Integration | API Gateway + Lambda |
| 9 | API network restrictions | Security | Private API access control |
| 10 | Scheduled invocation | Automation | EventBridge configuration |
| 11 | Compute integration test | End-to-End Testing | Service connectivity |
| 12 | Final flag | Challenge Completion | API endpoint functionality |

## 🛠️ Available Scripts

| Script | Purpose | Usage |
|--------|---------|-------|
| `deploy.sh` | Deploy challenge infrastructure | `bash deploy.sh` |
| `eval.sh` | Evaluate current state (12 checks) | `bash eval.sh` |
| `remediate.sh` | Fix all issues (instructor use) | `bash remediate.sh` |
| `teardown.sh` | Complete cleanup | `bash teardown.sh` |

## 🌐 Environment Setup

### AWS Environment Requirements
```bash
# Verify AWS CLI access (usually automatic in Learner Lab)
aws sts get-caller-identity

# IMPORTANT: AWS CloudShell Setup (Recommended)
# Create workspace directory with more storage (home ~ is only 1GB)
sudo mkdir -p /workspace
sudo chown cloudshell-user:cloudshell-user /workspace
cd /workspace

# Install jq if not available (required for eval.sh)
sudo yum install jq -y  # For Amazon Linux/CloudShell
# OR: sudo apt-get update && sudo apt-get install jq -y  # For Ubuntu
```

### Supported Environments
- **AWS CloudShell** (Recommended)
- **EC2 instances** with appropriate IAM roles
- **Local environment** with AWS CLI configured
- **WSL on Windows** with AWS CLI

### Complete Setup Example
```bash
# Complete setup from scratch in AWS CloudShell
sudo mkdir -p /workspace
sudo chown cloudshell-user:cloudshell-user /workspace
cd /workspace

git clone https://github.com/ethnus/CTF_MockTest_01.git
cd CTF_MockTest_01/scripts/
bash deploy.sh
bash eval.sh
```

## 🔧 Troubleshooting Guide

### Common Issues

**"No space left on device" or storage issues in AWS CloudShell**
```bash
# AWS CloudShell home directory (~) is limited to 1GB
# Use /workspace directory instead (has more storage)
sudo mkdir -p /workspace
sudo chown cloudshell-user:cloudshell-user /workspace
cd /workspace
# Then clone and run from here
```

**"terraform not found"**
```bash
# The deploy script auto-installs terraform
bash deploy.sh
```

**"AWS credentials not configured"**
```bash
# Configure AWS CLI with your Learner Lab credentials
aws configure
# Or use environment variables
export AWS_ACCESS_KEY_ID="your-key"
export AWS_SECRET_ACCESS_KEY="your-secret"
export AWS_SESSION_TOKEN="your-token"
```

**"jq command not found"**
```bash
# Install jq for your system
# Ubuntu/Debian:
sudo apt-get install jq
# macOS:
brew install jq
# Windows: Download from https://jqlang.github.io/jq/
```

**Evaluation shows errors**
- This is expected! The infrastructure is intentionally misconfigured
- Use AWS Console and CLI to investigate issues
- Fix one problem at a time
- Re-run `eval.sh` to track progress

### Investigation Tips

1. **Use AWS Console**
   - Check Lambda function configurations
   - Review VPC endpoint settings
   - Examine API Gateway setup
   - Verify resource tags

2. **Use AWS CLI**
   ```bash
   # Check Lambda function details
   aws lambda get-function --function-name ethnus-mocktest-01-writer
   
   # List VPC endpoints
   aws ec2 describe-vpc-endpoints
   
   # Check DynamoDB table
   aws dynamodb describe-table --table-name ethnus-mocktest-01-orders
   ```

3. **Read Error Messages**
   - The eval script provides specific error context
   - Look for patterns in failed checks
   - Use AWS documentation for reference

## 🎓 Learning Objectives

Upon completion, you will demonstrate proficiency in:

- **AWS Well-Architected Framework** principles
- **Serverless architecture** design and implementation  
- **VPC networking** and security controls
- **Encryption and key management** with KMS
- **Infrastructure as Code** with Terraform
- **Security best practices** and compliance
- **Troubleshooting methodologies** for cloud systems
- **API Gateway** and Lambda integrations
- **Resource tagging** and governance

## 💡 Best Practices Reinforced

- **Least Privilege Access** - Restrict IAM and resource policies
- **Defense in Depth** - Multiple security layers
- **Encryption Everywhere** - Data at rest and in transit
- **Resource Tagging** - Consistent labeling for governance
- **Infrastructure as Code** - Versioned, repeatable deployments
- **Monitoring and Logging** - Observability throughout
- **Cost Optimization** - Efficient resource utilization

---

<details>
<summary><strong>🚨 SPOILER ALERT - Challenge Details & Solutions</strong></summary>

> **⚠️ WARNING**: The following section contains detailed challenge descriptions and solution hints. Only expand if you're an instructor or have completed the challenge!

## 🎯 Detailed Challenge Breakdown

### Challenge 1: Tags - Object Storage
**Issue**: S3 bucket missing required tags  
**Fix**: Add `Owner=Ethnus` and `Challenge=ethnus-mocktest-01` tags  
**Command**: `aws s3api put-bucket-tagging --bucket <bucket-name> --tagging 'TagSet=[{Key=Owner,Value=Ethnus},{Key=Challenge,Value=ethnus-mocktest-01}]'`

### Challenge 2: Tags - Key-Value Database  
**Issue**: DynamoDB table missing required tags  
**Fix**: Add same tags to DynamoDB table  
**Command**: `aws dynamodb tag-resource --resource-arn <table-arn> --tags Key=Owner,Value=Ethnus Key=Challenge,Value=ethnus-mocktest-01`

### Challenge 3: Compute Concurrency
**Issue**: Lambda writer function has concurrency limit of 0  
**Fix**: Remove concurrency limit to allow execution  
**Command**: `aws lambda delete-function-concurrency --function-name ethnus-mocktest-01-writer`

### Challenge 4: Compute Configuration
**Issue**: Lambda writer has wrong DDB_TABLE environment variable  
**Fix**: Update environment variable to correct table name  
**Command**: `aws lambda update-function-configuration --function-name ethnus-mocktest-01-writer --environment Variables='{DDB_TABLE=ethnus-mocktest-01-orders,BUCKET=<bucket>,TOPIC_ARN=<topic>}'`

### Challenge 5: Notifications Publish
**Issue**: SNS topic policy doesn't allow publishing  
**Fix**: Add policy allowing publish from account owner  
**Solution**: Update SNS topic policy with proper permissions

### Challenge 6: Private Data Endpoint Policy
**Issue**: DynamoDB VPC endpoint policy too restrictive  
**Fix**: Update VPC endpoint policy to allow DynamoDB PutItem  
**Solution**: Modify VPC endpoint policy to include `dynamodb:PutItem` action

### Challenge 7: Network Endpoints Routing
**Issue**: VPC endpoints not associated with main route table  
**Fix**: Associate S3 and DynamoDB gateway endpoints with main route table  
**Command**: `aws ec2 modify-vpc-endpoint --vpc-endpoint-id <endpoint-id> --add-route-table-ids <route-table-id>`

### Challenge 8: API Integration
**Issue**: API Gateway /orders resource not properly integrated with Lambda  
**Fix**: Ensure API Gateway resource exists and is connected to reader Lambda  
**Solution**: Create resource, method, and integration in API Gateway

### Challenge 9: API Network Restrictions
**Issue**: API Gateway policy missing VPC endpoint condition  
**Fix**: Update API Gateway policy to restrict access to specific VPC endpoint  
**Solution**: Add `aws:SourceVpce` condition to API Gateway resource policy

### Challenge 10: Scheduled Invocation
**Issue**: EventBridge rule is disabled  
**Fix**: Enable the EventBridge rule  
**Command**: `aws events enable-rule --name ethnus-mocktest-01-tick`

### Challenge 11: Compute Integration Test
**Issue**: Lambda writer cannot access DynamoDB, S3, or SNS  
**Fix**: Requires fixes from previous challenges to work properly  
**Verification**: Lambda function should return `{"ddb_ok": true, "s3_ok": true, "sns_ok": true}`

### Challenge 12: Final Flag
**Issue**: API Gateway /orders endpoint not accessible or functioning  
**Fix**: Requires all previous challenges to be completed  
**Success**: API returns `{"flag": "ETHNUS{w3ll_4rch1t3ct3d_cl0ud_s3cur1ty_2025}"}`

## 🏆 Success Criteria

### Evaluation Results
When all challenges are completed, `bash eval.sh` should show:
```
ACCEPTED   : 12
INCOMPLETE : 0
```

### Final Flag
The final API call should return:
```json
{
  "flag": "ETHNUS{w3ll_4rch1t3ct3d_cl0ud_s3cur1ty_2025}"
}
```

</details>

---

## 📞 Support

- **Students**: Use AWS documentation, CloudWatch logs, and systematic troubleshooting
- **Instructors**: Run `remediate.sh` to see working configuration examples
- **Issues**: Check script output for specific error messages and context

## 📄 License

This project is designed for educational purposes as part of the Ethnus AWS training program.

---

**Good luck with your cloud architecture challenge! 🚀**
