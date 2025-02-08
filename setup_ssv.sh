#!/bin/bash

# Variables
PROGRESS_FILE="/var/log/ssv_setup_progress.log"
LOG_FILE="$HOME/ssv_setup.log"
HOSTNAME=$(hostname)
USERNAME=$(whoami)

# Redirect output to log file
exec > >(tee -a "$LOG_FILE") 2>&1

log_progress() {
    echo "$1" | sudo tee "$PROGRESS_FILE"
}

get_last_step() {
    if [ -f "$PROGRESS_FILE" ]; then
        cat "$PROGRESS_FILE"
    else
        echo "0"
    fi
}

LAST_STEP=$(get_last_step)
echo "===== SSV Setup Script Started on $(date) ====="
echo "Last completed step: $LAST_STEP"

# Ensure Git is installed before doing anything
if ! command -v git &> /dev/null; then
    echo "📌 Installing Git..."
    sudo apt update -y
    sudo apt install -y git
fi

# Ensure the script is the latest version
if [ "$LAST_STEP" -lt 1 ]; then
    echo "📌 Checking for the latest SSV-Setup script..."
    if [ -d "$HOME/SSV-Setup" ]; then
        cd "$HOME/SSV-Setup" && git pull origin main
    else
        git clone https://github.com/Chadgoyette/SSV-Setup.git "$HOME/SSV-Setup"
    fi
    log_progress "1"
fi

# Step 1: Set up Swap File
if [ "$LAST_STEP" -lt 2 ]; then
    echo "📌 Checking swap file..."
    if ! swapon --show | grep -q "/swapfile"; then
        echo "Creating swap file..."
        sudo fallocate -l 1G /swapfile
        sudo chmod 600 /swapfile
        sudo mkswap /swapfile
        sudo swapon /swapfile
        echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab
    else
        echo "✅ Swap file already exists. Skipping."
    fi
    log_progress "2"
    sudo reboot
fi

# Step 2: Install Wyoming Satellite
if [ "$LAST_STEP" -lt 3 ]; then
    echo "📌 Installing Wyoming Satellite..."
    sudo apt update -y
    sudo apt install -y python3 python3-venv python3-pip git

    if [ ! -d "$HOME/wyoming-satellite" ]; then
        git clone https://github.com/rhasspy/wyoming-satellite.git "$HOME/wyoming-satellite"
    fi

    cd "$HOME/wyoming-satellite" || exit
    python3 -m venv venv
    source venv/bin/activate
    pip install -r requirements.txt
    pip install boost
    export BOOST_INCLUDEDIR=/usr/include/boost
    deactivate
    log_progress "3"
    sudo reboot
fi

# Step 3: Configure Wyoming Satellite
if [ "$LAST_STEP" -lt 4 ]; then
    echo "📌 Configuring Wyoming Satellite..."
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

[Install]
WantedBy=multi-user.target
EOL

    # Reload systemd and enable the service
    sudo systemctl daemon-reload
    sudo systemctl enable wyoming-satellite
    sudo systemctl start wyoming-satellite
    log_progress "4"
fi

# Step 4: Stop Wyoming & LED services before PulseAudio
if [ "$LAST_STEP" -lt 5 ]; then
    echo "📌 Stopping Wyoming & LED services..."
    sudo systemctl stop wyoming-satellite || true
    sudo systemctl stop led-service || true
    log_progress "5"
fi

# Step 5: Install PulseAudio
if [ "$LAST_STEP" -lt 6 ]; then
    echo "📌 Installing PulseAudio and Dependencies..."
    sudo apt install -y pulseaudio pulseaudio-utils git wget curl alsa-utils python3 python3-pip jq libasound2 avahi-daemon libboost-all-dev
    log_progress "6"
fi

# Step 6: Install Wyoming Enhancements
if [ "$LAST_STEP" -lt 7 ]; then
    echo "📌 Installing Wyoming Enhancements..."
    if [ ! -d "$HOME/wyoming-enhancements" ]; then
        git clone https://github.com/FutureProofHomes/wyoming-enhancements.git "$HOME/wyoming-enhancements"
    fi
    log_progress "7"
fi

# Step 7: Install Snapclient
if [ "$LAST_STEP" -lt 8 ]; then
    echo "📌 Installing Snapclient..."
    SNAP_VERSION="0.31.0"
    SNAP_URL="https://github.com/badaix/snapcast/releases/download/v${SNAP_VERSION}/snapclient_${SNAP_VERSION}-1_armhf_bookworm_with-pulse.deb"

    wget -O snapclient.deb "$SNAP_URL"
    sudo dpkg -i snapclient.deb
    sudo apt --fix-broken install -y
    rm -f snapclient.deb

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
    log_progress "8"
fi

# Step 8: Apply Wyoming Enhancements Modifications
if [ "$LAST_STEP" -lt 9 ]; then
    echo "📌 Applying Wyoming Satellite modifications..."
    MODIFY_WYOMING_SCRIPT="$HOME/wyoming-enhancements/snapcast/modify_wyoming_satellite.sh"
    if [ -f "$MODIFY_WYOMING_SCRIPT" ]; then
        bash "$MODIFY_WYOMING_SCRIPT"
    fi
    sudo systemctl restart wyoming-satellite
    log_progress "9"
fi

echo "===== SSV Setup Completed Successfully on $(date) ====="
