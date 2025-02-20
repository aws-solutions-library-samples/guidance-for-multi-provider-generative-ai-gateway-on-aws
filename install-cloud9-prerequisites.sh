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