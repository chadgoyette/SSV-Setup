#!/bin/bash
# SSV Setup Script for Snapcast, PulseAudio, Wyoming Satellite, and Enhancements
# Logs to /var/log/ssv_setup.log

LOGFILE="/var/log/ssv_setup.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "===== SSV Setup Script Started on $(date) ====="

# Exit on error
set -e

# Function to handle errors
error_exit() {
    echo "❌ ERROR: $1"
    exit 1
}

# Update package lists
echo "Updating package lists..."
sudo apt update || error_exit "Failed to update packages"

# Upgrade system packages
echo "Upgrading system packages..."
sudo apt upgrade -y || error_exit "Failed to upgrade packages"

# Increase Swap Space (for dependency installations)
echo "Checking swap size..."
sudo fallocate -l 1G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo "Swap space increased."

# Install Required Dependencies
echo "Installing dependencies..."
sudo apt install -y \
    snapcast \
    pulseaudio \
    pulseaudio-utils \
    python3-pip \
    python3-venv \
    git || error_exit "Failed to install dependencies"

# Setup PulseAudio System Mode
echo "Configuring PulseAudio to run in system mode..."
sudo mkdir -p /etc/pulse/
sudo tee /etc/pulse/system.pa > /dev/null <<EOL
#!/usr/bin/pulseaudio -nF

# Auto-restore devices
load-module module-device-restore
load-module module-stream-restore
load-module module-card-restore

# Auto-load drivers
.ifexists module-udev-detect.so
load-module module-udev-detect
.else
load-module module-detect
.endif

# Enable protocols
load-module module-native-protocol-unix

# Default device restore
load-module module-default-device-restore

# Always have a fallback sink
load-module module-always-sink

# Suspend idle sinks
load-module module-suspend-on-idle

# Enable volume ducking
load-module module-role-ducking trigger_roles=announce,phone,notification,event ducking_roles=any_role volume=33%

# Load Seeed Voicecard (Ensure correct hw:1,0 path)
load-module module-alsa-sink device=hw:1,0 sink_name=seeed_sink
set-default-sink seeed_sink
EOL

# Enable PulseAudio system service
echo "Setting up PulseAudio system service..."
sudo tee /etc/systemd/system/pulseaudio.service > /dev/null <<EOL
[Unit]
Description=PulseAudio system server
After=network.target

[Service]
ExecStart=/usr/bin/pulseaudio --system --disallow-exit --disable-shm
Restart=always
User=pulse

[Install]
WantedBy=multi-user.target
EOL

# Enable and start PulseAudio
sudo systemctl daemon-reload
sudo systemctl enable pulseaudio.service
sudo systemctl restart pulseaudio.service || error_exit "Failed to start PulseAudio"

# Install Wyoming Satellite
echo "Installing Wyoming Satellite..."
git clone https://github.com/mikejgray/wyoming-satellite.git ~/wyoming-satellite
cd ~/wyoming-satellite
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt || error_exit "Failed to install Wyoming dependencies"
deactivate

# Setup Wyoming Satellite Service
echo "Setting up Wyoming Satellite as a systemd service..."
sudo tee /etc/systemd/system/wyoming.service > /dev/null <<EOL
[Unit]
Description=Wyoming Satellite Voice Assistant
After=network.target

[Service]
ExecStart=/home/SSV2/wyoming-satellite/venv/bin/python3 /home/SSV2/wyoming-satellite/wyoming-satellite.py
Restart=always
User=SSV2

[Install]
WantedBy=multi-user.target
EOL

# Enable and start Wyoming Satellite
sudo systemctl daemon-reload
sudo systemctl enable wyoming.service
sudo systemctl restart wyoming.service || error_exit "Failed to start Wyoming Satellite"

# Setup Snapcast Client
echo "Configuring Snapcast Client..."
sudo tee /etc/systemd/system/snapclient.service > /dev/null <<EOL
[Unit]
Description=Snapcast Client
After=network.target pulseaudio.service

[Service]
ExecStart=/usr/bin/snapclient --player pulse
Restart=always
User=snapclient

[Install]
WantedBy=multi-user.target
EOL

# Enable and start Snapcast Client
sudo systemctl daemon-reload
sudo systemctl enable snapclient.service
sudo systemctl restart snapclient.service || error_exit "Failed to start Snapcast Client"

# Cleanup and remove swap
echo "Removing temporary swap file..."
sudo swapoff /swapfile
sudo rm /swapfile

echo "===== SSV Setup Completed Successfully on $(date) ====="
