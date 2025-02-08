#!/bin/bash

HOSTNAME=$(hostname)
USERNAME=$(whoami)
LOG_FILE="/var/log/ssv_setup.log"

exec > >(tee -a $LOG_FILE) 2>&1

echo "===== SSV Setup Script Started on $(date) ====="

# Update package lists and upgrade system
sudo apt update -y
sudo apt upgrade -y

# Ensure swap size is adequate
sudo fallocate -l 1G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
sudo bash -c 'echo "/swapfile none swap sw 0 0" >> /etc/fstab'

# Step 1: Install Wyoming Satellite
if [ ! -d "$HOME/wyoming-satellite" ]; then
    echo "Cloning Wyoming Satellite repository..."
    git clone https://github.com/rhasspy/wyoming-satellite.git ~/wyoming-satellite
fi
cd ~/wyoming-satellite || exit

# Install system dependencies
sudo apt install -y python3 python3-venv python3-pip portaudio19-dev flac

# Install and enable ReSpeaker 2-Mic HAT driver
if [ ! -d "/usr/share/seeed_voicecard" ]; then
    echo "Installing ReSpeaker 2-Mic HAT driver..."
    git clone --depth=1 https://github.com/respeaker/seeed-voicecard.git
    cd seeed-voicecard || exit
    sudo ./install.sh
    cd ..
    rm -rf seeed-voicecard
fi

# Set up Python virtual environment
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
pip install boost
BOOST_INCLUDEDIR=/usr/include/boost
export BOOST_INCLUDEDIR

# Install additional dependencies for ReSpeaker 2-Mic HAT
pip install pyaudio numpy

deactivate

# Create Wyoming Satellite Configuration
CONFIG_FILE="$HOME/wyoming-satellite/config.yml"
cat <<EOL > "$CONFIG_FILE"
server:
  bind: 0.0.0.0
  port: 10300

audio:
  frame-width: 512
  sampling-rate: 16000
  sample-format: s16le
  channels: 1

plugins:
  snapcast:
    host: localhost
    port: 1704
    stream_name: "$HOSTNAME"
EOL

# Create a systemd service for Wyoming Satellite
SERVICE_FILE="/etc/systemd/system/wyoming-satellite.service"
cat <<EOL | sudo tee "$SERVICE_FILE"
[Unit]
Description=Wyoming Satellite Service
After=network.target

[Service]
ExecStart=/home/$USERNAME/wyoming-satellite/venv/bin/python /home/$USERNAME/wyoming-satellite/main.py
WorkingDirectory=/home/$USERNAME/wyoming-satellite
Restart=always
User=$USERNAME
Group=audio

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable wyoming-satellite
sudo systemctl start wyoming-satellite

# Stop Wyoming Satellite and LED services before modifying PulseAudio
sudo systemctl stop wyoming-satellite || true
sudo systemctl stop led-service || true

# Step 2: Install PulseAudio and Dependencies
sudo apt install -y pulseaudio pulseaudio-utils git wget curl alsa-utils python3 python3-pip jq libasound2 avahi-daemon libboost-all-dev

# Add pulse user and group for system mode
sudo groupadd -r pulse
sudo useradd -r -g pulse -G audio -d /var/run/pulse pulse
sudo usermod -aG pulse-access $USERNAME

# Configure PulseAudio for system mode
sudo mkdir -p /etc/pulse
sudo tee /etc/pulse/system.pa <<EOL
#!/usr/bin/pulseaudio -nF
load-module module-native-protocol-unix
load-module module-udev-detect
load-module module-alsa-sink device=hw:1,0 sink_name=seeed_sink
load-module module-always-sink
EOL

# Set permissions and restart PulseAudio
sudo chmod 644 /etc/pulse/system.pa
sudo systemctl restart pulseaudio

# Step 3: Install Wyoming Enhancements
if [ ! -d "$HOME/wyoming-enhancements" ]; then
    echo "Cloning Wyoming Enhancements repository..."
    git clone https://github.com/FutureProofHomes/wyoming-enhancements.git ~/wyoming-enhancements
fi

# Step 4: Install Snapcast from GitHub Release
SNAP_VERSION="0.31.0"
SNAP_URL="https://github.com/badaix/snapcast/releases/download/v${SNAP_VERSION}/snapclient_${SNAP_VERSION}-1_armhf_bookworm_with-pulse.deb"

if ! command -v snapclient &> /dev/null; then
    echo "Downloading and installing Snapcast..."
    wget -O snapclient.deb "$SNAP_URL"
    sudo dpkg -i snapclient.deb
    sudo apt --fix-broken install -y
    rm -f snapclient.deb
fi

if ! command -v snapclient &> /dev/null; then
    echo "❌ ERROR: Snapclient installation failed."
    exit 1
fi

sudo systemctl enable snapclient
sudo systemctl start snapclient

# Ensure Snapcast service uses the correct hostname
SNAPCAST_CONFIG="/etc/default/snapclient"
cat <<EOL | sudo tee "$SNAPCAST_CONFIG"
SNAPCLIENT_OPTS="-h localhost -s $HOSTNAME"
EOL

sudo systemctl restart snapclient

# Step 5: Apply Wyoming Enhancements Modifications
MODIFY_WYOMING_SCRIPT="$HOME/wyoming-enhancements/snapcast/modify_wyoming_satellite.sh"
if [ -f "$MODIFY_WYOMING_SCRIPT" ]; then
    echo "Applying Wyoming Satellite modifications..."
    bash "$MODIFY_WYOMING_SCRIPT"
fi

sudo systemctl restart wyoming-satellite

echo "===== SSV Setup Completed Successfully on $(date) ====="
