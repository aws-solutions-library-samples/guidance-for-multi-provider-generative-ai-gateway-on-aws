#!/bin/bash

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if yq is installed
if command_exists yq; then
    echo "yq is already installed"
    yq --version
else
    echo "yq is not installed. Installing now..."
    
    # Set the version
    VERSION="v4.40.5"
    BINARY="yq_linux_amd64"
    
    # Check if script is run with sudo
    if [ "$EUID" -ne 0 ]; then 
        echo "Please run with sudo privileges"
        exit 1
    fi
    
    # Download yq
    if wget https://github.com/mikefarah/yq/releases/download/${VERSION}/${BINARY} -O /usr/bin/yq; then
        # Make it executable
        chmod +x /usr/bin/yq
        
        echo "yq has been successfully installed"
        yq --version
    else
        echo "Failed to download yq"
        exit 1
    fi
fi

sudo yum update -y

# Install required dependencies
sudo yum install -y yum-utils unzip wget

# Download the signing key
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --import -

# Add the HashiCorp repository
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo

# Install Terraform
sudo yum install -y terraform

# Verify installation
terraform version

curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

kubectl version --client