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

# Step 1: Install Wyoming Satellite (Following the Official Tutorial)
echo "===== Installing Wyoming Satellite ====="

# Ensure dependencies are installed
sudo apt install -y python3 python3-venv python3-pip portaudio19-dev flac

# Clone the Wyoming Satellite repository
if [ ! -d "$HOME/wyoming-satellite" ]; then
    echo "Cloning Wyoming Satellite repository..."
    git clone https://github.com/rhasspy/wyoming-satellite.git ~/wyoming-satellite
fi

# Navigate into the directory
cd ~/wyoming-satellite || exit

# Create and activate a virtual environment
python3 -m venv venv
source venv/bin/activate

# Install required Python packages
pip install -U pip
pip install -r requirements.txt

# Install Boost manually to avoid header path issues
pip install boost
BOOST_INCLUDEDIR=/usr/include/boost
export BOOST_INCLUDEDIR

# Install additional dependencies for ReSpeaker 2-Mic HAT
pip install pyaudio numpy

# Deactivate the virtual environment
deactivate

# Create Wyoming Satellite Configuration File
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
EOL

# Remove existing Wyoming Satellite service file if it exists
SERVICE_FILE="/etc/systemd/system/wyoming-satellite.service"
if [ -f "$SERVICE_FILE" ]; then
    sudo rm "$SERVICE_FILE"
fi

# Create a new Wyoming Satellite service file
cat <<EOL | sudo tee "$SERVICE_FILE"
[Unit]
Description=Wyoming Satellite
Wants=network-online.target
After=network-online.target
Requires=wyoming-openwakeword.service
Requires=2mic_leds.service

[Service]
Type=simple
ExecStart=/home/$USERNAME/wyoming-satellite/script/run \
  --name '$USERNAME' \
  --uri 'tcp://0.0.0.0:10700' \
  --mic-command 'arecord -D plughw:CARD=seeed2micvoicec,DEV=0 -r 16000 -c 1 -f S16_LE -t raw' \
  --snd-command 'aplay -D plughw:CARD=seeed2micvoicec,DEV=0 -r 22050 -c 1 -f S16_LE -t raw' \
  --wake-uri 'tcp://127.0.0.1:10400' \
  --wake-word-name 'hey_jarvis' \
  --event-uri 'tcp://127.0.0.1:10500'
WorkingDirectory=/home/$USERNAME/wyoming-satellite
Restart=always
RestartSec=1

[Install]
WantedBy=default.target
EOL

# Step: Install Local Wake Word Detection (openWakeWord)
echo "Installing local wake word detection (openWakeWord)..."

# Install necessary dependencies
sudo apt-get update
sudo apt-get install --no-install-recommends -y libopenblas-dev

# Clone and set up openWakeWord
if [ ! -d "$HOME/wyoming-openwakeword" ]; then
    git clone https://github.com/rhasspy/wyoming-openwakeword.git ~/wyoming-openwakeword
fi

cd ~/wyoming-openwakeword || exit
script/setup

# Remove existing Wyoming OpenWakeWord service file if it exists
WAKEWORD_SERVICE_FILE="/etc/systemd/system/wyoming-openwakeword.service"
if [ -f "$WAKEWORD_SERVICE_FILE" ]; then
    sudo rm "$WAKEWORD_SERVICE_FILE"
fi

# Create systemd service for openWakeWord
cat <<EOL | sudo tee "$WAKEWORD_SERVICE_FILE"
[Unit]
Description=Wyoming openWakeWord

[Service]
Type=simple
ExecStart=/home/$USERNAME/wyoming-openwakeword/script/run --uri 'tcp://127.0.0.1:10400'
WorkingDirectory=/home/$USERNAME/wyoming-openwakeword
Restart=always
RestartSec=1

[Install]
WantedBy=default.target
EOL

# Step: Install and Configure LED Service for ReSpeaker 2Mic HAT
echo "Setting up LED service for ReSpeaker 2Mic HAT..."

# Navigate to the Wyoming Satellite examples directory
cd ~/wyoming-satellite/examples || exit

# Set up a Python virtual environment for the LED service
python3 -m venv --system-site-packages .venv
.venv/bin/pip3 install --upgrade pip
.venv/bin/pip3 install --upgrade wheel setuptools
.venv/bin/pip3 install 'wyoming==1.5.2'

# Install additional dependencies if required
sudo apt-get install -y python3-spidev python3-gpiozero

# Test the service to ensure it runs correctly
.venv/bin/python3 2mic_service.py --help

# Remove existing LED service file if it exists
LED_SERVICE_FILE="/etc/systemd/system/2mic_leds.service"
if [ -f "$LED_SERVICE_FILE" ]; then
    sudo rm "$LED_SERVICE_FILE"
fi

# Create systemd service for LED control
cat <<EOL | sudo tee "$LED_SERVICE_FILE"
[Unit]
Description=2Mic LEDs

[Service]
Type=simple
ExecStart=/home/$USERNAME/wyoming-satellite/examples/.venv/bin/python3 2mic_service.py --uri 'tcp://127.0.0.1:10500'
WorkingDirectory=/home/$USERNAME/wyoming-satellite/examples
Restart=always
RestartSec=1

[Install]
WantedBy=default.target
EOL


# Reload systemd and restart the service
sudo systemctl daemon-reload
sudo systemctl enable wyoming-satellite
sudo systemctl restart wyoming-satellite

echo "===== Wyoming Satellite Installation Complete ====="

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
