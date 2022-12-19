
# Variables
USAGE="Usage: $0 [your target AWS region] [your security group name]\n\nExample:\n$0 us-east-1 ContrastDemo-Sam-Spade"
REGION_AWS=$1
GROUP_NAME=$2
HDE_PROFILE_NAME=contrast-hde

if [[ $# -ne 1 ]]; then
  echo -e $USAGE
  exit 1
fi

# Add current IP to ContrastDemo security group
CURRENT_IP=$(curl -s https://checkip.amazonaws.com)
echo "Updating '${GROUP_NAME}' EC2 security group in region '${REGION_AWS}' to allow inbound access from ${CURRENT_IP} to port 3389..."
ADD_IP_TO_DEMO_SG=$(aws --profile $HDE_PROFILE_NAME --region $REGION_AWS ec2 authorize-security-group-ingress --group-name $GROUP_NAME --protocol tcp --port 3389 --cidr $CURRENT_IP/32)
