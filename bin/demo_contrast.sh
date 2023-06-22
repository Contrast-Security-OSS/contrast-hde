#!/bin/bash
# Launches Contrast Security SE virtual Windows developer workstation in AWS for demo purposes
# This script is meant to be run on MacOS

# Variables
DEFAULT_DEMO_AMI="PlatformDemo-1.3a" # This value should updated whenever a new AMI for the Contrast demo "golden image" is created
USAGE="Usage: $0 [demo version] [customer name or description] [your name] [your target AWS region] [hours to keep demo running]\n\nExample:\n$0 default 'Acme Corp' 'Sam Spade' us-west-1 2"
VERSION=$1
CUSTOMER=$2
CONTACT=$3
REGION_AWS=$4 # For a list of AWS regions, look here: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.RegionsAndAvailabilityZones.html
TTL=$5
ALARM_PERIOD=900 # CloudWatch alarm period of 900 seconds (15 minutes)
TTL_BUFFER=2 # Number of additional $ALARM_PERIOD duration buffers before automatic termination of demo instances
TTL_PERIODS=0
CREATION_TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
INSTANCE_TYPE=t3.xlarge
HDE_PROFILE_NAME=contrast-hde
NETSKOPE_IP_CIDR="163.116.128.0/17"
PUBLIC_IP=""
PING_COUNT=3
DESKTOP_WIDTH=2560
DESKTOP_HEIGHT=1600

# Check if all expected arguments were provided
if [[ $# -ne 5 ]]; then
  echo -e $USAGE
  exit 1
fi

aws configure list-profiles | grep -q $HDE_PROFILE_NAME
retVal=$?

if [ $retVal -ne 0 ]; then
  echo "$HDE_PROFILE_NAME does not exist..";
  echo "Please run 'aws configure sso --profile $HDE_PROFILE_NAME' to configure your AWS SSO profile.";
  exit 1
else
  echo "$HDE_PROFILE_NAME already exists.."
  echo "Logging out of $HDE_PROFILE_NAME profile.."
  aws sso logout --profile $HDE_PROFILE_NAME
  retVal=$?
  if [ $retVal -ne 0 ]; then
    echo "ERROR: Failed to logout of $HDE_PROFILE_NAME profile."
    exit 1
  else
    echo "Logged out of $HDE_PROFILE_NAME profile."
    echo "Logging in to $HDE_PROFILE_NAME profile.."
    aws sso login --profile $HDE_PROFILE_NAME
    retVal=$?
    if [ $retVal -ne 0 ]; then
      echo "ERROR: Failed to login to $HDE_PROFILE_NAME profile."
      exit 1
    fi
  fi
fi

# Get the AMI ID of the latest HDE "Golden Image"
# The 'default' AMI name is hde-0.1.0 as of August 31, 2018.
if [[ $VERSION = default ]]; then
  VERSION=$DEFAULT_DEMO_AMI # This value should be set to the name of the latest Contrast demo AMI
fi
echo "${CREATION_TIMESTAMP} - Input version is: ${VERSION}"
AMI_ID="$(aws --profile ${HDE_PROFILE_NAME} ec2 describe-images --filters "Name=name,Values=${VERSION}" --region=${REGION_AWS} | grep -o "ami-[a-zA-Z0-9_]*")"
if [ ! -z $AMI_ID ]; then
  echo "Found matching AMI (${AMI_ID})..."
else
  echo "ERROR: Could not find matching AMI named ${VERSION} in the ${REGION_AWS} region."
  exit 1
fi

# Create instance Name tag
TAG_NAME="${CUSTOMER}-${CONTACT}"

# Create log directory if it does not already exist
if [ ! -d "logs" ]; then
  mkdir -p logs
fi

# Get Default VPC ID
DEFAULT_VPC_ID=$(aws --profile $HDE_PROFILE_NAME --region $REGION_AWS ec2 describe-vpcs --filters "Name=is-default,Values=true" --query "Vpcs[0].VpcId" | grep -o "vpc-[a-zA-Z0-9_]*")

# Define security group name
GROUP_NAME=ContrastDemo-$(echo $CONTACT | tr " " "-")

# Check if security group already exists
DESCRIBE_SG=$(aws --profile $HDE_PROFILE_NAME --region $REGION_AWS ec2 describe-security-groups --filters "Name=group-name,Values=$GROUP_NAME" --query "SecurityGroups[0].GroupName")
if [ $DESCRIBE_SG ] && [ $DESCRIBE_SG != "null" ]; then
  echo "Found existing security group: $DESCRIBE_SG"
else
  # Create a security group
  echo "Security group: $GROUP_NAME not found. Creating..."
  CREATE_SG=$(aws --profile $HDE_PROFILE_NAME --region $REGION_AWS ec2 create-security-group --group-name "$GROUP_NAME" --description "$CONTACT" --vpc-id $DEFAULT_VPC_ID)
fi

# Get current IP address
CURRENT_IP=$(curl -s https://checkip.amazonaws.com)

# Check if current IP address is in security group
SG_IP=$(aws --profile $HDE_PROFILE_NAME \
--region $REGION_AWS ec2 describe-security-groups \
--filters "Name=group-name,Values=$GROUP_NAME" "Name=ip-permission.from-port,Values=3389" "Name=ip-permission.to-port,Values=3389" "Name=ip-permission.cidr,Values=$CURRENT_IP/32" \
--query "SecurityGroups[0].IpPermissions[*].IpRanges[*].{CidrIp:CidrIp}")

if [ $SG_IP ] && [ $SG_IP != "null" ]; then
  echo "IP address: $CURRENT_IP already in security group: $GROUP_NAME"
else
  # Add current IP to security group
  echo "IP: $CURRENT_IP not in security group: $GROUP_NAME"
  echo "Adding IP: $CURRENT_IP to security group: $GROUP_NAME"
  ADD_IP_TO_DEMO_SG=$(aws --profile $HDE_PROFILE_NAME --region $REGION_AWS ec2 authorize-security-group-ingress --group-name "$GROUP_NAME" --protocol tcp --port 3389 --cidr $CURRENT_IP/32)
  ADD_IP_TO_DEMO_SG=$(aws --profile $HDE_PROFILE_NAME --region $REGION_AWS ec2 authorize-security-group-ingress --group-name "$GROUP_NAME" --protocol tcp --port 3389 --cidr $NETSKOPE_IP_CIDR)
fi

# Launch the AWS EC2 instance
LAUNCH_INSTANCE=$(aws --profile $HDE_PROFILE_NAME ec2 run-instances \
--image-id $AMI_ID \
--count 1 \
--instance-type $INSTANCE_TYPE \
--security-groups "$GROUP_NAME" \
--tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${TAG_NAME}},{Key=Owner,Value=${CONTACT}},{Key=Demo-Version,Value=${VERSION}},{Key=x-purpose,Value='demo'},{Key=x-creation-timestamp,Value=${CREATION_TIMESTAMP}}]" \
--block-device-mapping "DeviceName=/dev/sda1,Ebs={DeleteOnTermination=true}" \
--region=$REGION_AWS \
> "logs/demo_instance_${REGION_AWS}_${CREATION_TIMESTAMP}.log")

if [ $LAUNCH_INSTANCE ]; then
  echo "Something went wrong, launching the EC2 instance failed!  Please try again or contact the Contrast Sales Engineering team for assistance."
  exit 1
fi

# Get the Instance ID of the newly created instance
INSTANCEID="$(aws --profile ${HDE_PROFILE_NAME} ec2 describe-instances --region=${REGION_AWS} --filters "Name=tag:Name,Values=${TAG_NAME}" "Name=instance-state-name,Values=pending" | grep InstanceId | grep -o "i-[a-zA-Z0-9_]*")"

if [ ! -z $INSTANCEID ]; then
  echo -e "\nLaunching Contrast virtual Windows developer workstation..."

  # Get public IP address of the newly created instance
  PUBLIC_IP="$(aws --profile ${HDE_PROFILE_NAME} ec2 describe-instances --region=${REGION_AWS} --filters "Name=tag:Name,Values=${TAG_NAME}" "Name=instance-id,Values=${INSTANCEID}" | grep PublicIpAddress | grep -Eo "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}")"
  echo -e "  InstanceID: ${INSTANCEID}"
  echo -e "  Public IP: ${PUBLIC_IP}"
  echo -e "\nWait about 10 minutes, then open your remote desktop client and connect to ${PUBLIC_IP} as 'Administrator'."
  echo -e "If you do not know the password, please ask your friendly neighborhood sales engineer."

  if [ $TTL -gt 0 ]; then
    # Check if the TTL value is greater than 24, and if so, then set it to the maximum alarm duration allowed by CloudWatch, which is 24
    if [ $TTL -gt 23 ]; then
      TTL=24
      TTL_PERIODS=$(expr $TTL \* 3600 / $ALARM_PERIOD)
      echo -e "\nThe maximum allowed CloudWatch alarm duration is 24 hours.  Resetting the auto-termination alarm to trigger after 24 hours."
    else
      TTL_PERIODS=$(expr $TTL \* 3600 / $ALARM_PERIOD + $TTL_BUFFER)
    fi
    # Set unique name for the CloudWatch alarm
    ALARM_NAME="Auto-terminate ${INSTANCEID} after ${TTL} hours"

    # Set CloudWatch alarm to automatically terminate the EC2 instance when the TTL expires
    TERMINATION_ALARM=$(aws --profile $HDE_PROFILE_NAME --region=${REGION_AWS} cloudwatch put-metric-alarm \
    --alarm-name "${ALARM_NAME}" \
    --alarm-description "Terminate instance after ${TTL} hours" \
    --namespace AWS/EC2 \
    --metric-name CPUUtilization \
    --unit Percent \
    --statistic Average \
    --period $ALARM_PERIOD \
    --evaluation-periods $TTL_PERIODS \
    --threshold 0 \
    --comparison-operator GreaterThanOrEqualToThreshold \
    --dimensions "Name=InstanceId,Value=${INSTANCEID}" \
    --alarm-actions arn:aws:automate:$REGION_AWS:ec2:terminate)

    if [ $TERMINATION_ALARM ]; then
      aws --profile $HDE_PROFILE_NAME --region=${REGION_AWS} ec2 terminate-instances --instance-ids $INSTANCEID
      echo "Something went wrong, setting the alarm to automatically terminate this instance failed!  Please try again or contact the Contrast Sales Engineering team for assistance."
      exit 1
    else
      echo -e "\nYour workstation will automatically terminate after ${TTL} hour(s)."
    fi
  else
    # No alarm will be set and this instance will need to be auto-terminated
    echo -e "\n*** PLEASE NOTE THAT THIS NEW INSTANCE WILL NOT BE AUTOMATICALLY TERMINATED ***"
  fi

  # Sleep 2 minutes and then check if the new instance is network accessible
  echo -e "\nNow let's wait for 2 minutes and then check if the instance is ready..."
  sleep 120

  # Check if the new instance is publicly accessible every 10 seconds
  while true; do
    NC_RESPONSE="$(nc -zv -G 1 ${PUBLIC_IP} 3389 &> /dev/null && echo "Online" || echo "Offline")"
    if [ "${NC_RESPONSE}" = "Online" ]
    then
      echo "$NC_RESPONSE"
      # If the instance is available, then launch Microsoft Remote Desktop to connect
      echo -e "Opening Microsoft Remote Desktop session to your new virtual Windows developer workstation!"
      open -Fa /Applications/Microsoft\ Remote\ Desktop.app "rdp://full%20address=s:${PUBLIC_IP}&audiomode=i:0&disable%20themes=i:1&screen%20mode%20id=i:2&smart%20sizing=i:1&username=s:Administrator&session%20bpp=i:32&allow%20font%20smoothing=i:1&prompt%20for%20credentials%20on%20client=i:0&disable%20full%20window%20drag=i:1&autoreconnection%20enabled=i:1"
      # open -Fa /Applications/Microsoft\ Remote\ Desktop.app "rdp://full%20address=s:${PUBLIC_IP}&audiomode=i:0&disable%20themes=i:1&desktopwidth:i:${DESKTOP_WIDTH}&desktopheight:i:${DESKTOP_HEIGHT}&screen%20mode%20id=i:2&smart%20sizing=i:1&username=s:Administrator&session%20bpp=i:32&allow%20font%20smoothing=i:1&prompt%20for%20credentials%20on%20client=i:0&disable%20full%20window%20drag=i:1&autoreconnection%20enabled=i:1"
      break
    else
      echo "$NC_RESPONSE"
      sleep 10
    fi
  done
fi
