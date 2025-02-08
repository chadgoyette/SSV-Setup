#!/bin/bash

# Variables
PROGRESS_FILE="/var/log/ssv_setup_progress.log"
HOSTNAME=$(hostname)
USERNAME=$(whoami)

# Function to log progress
log_progress() {
    echo "$1" | sudo tee "$PROGRESS_FILE"
}

# Function to get last completed step
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

# If reboot is required, resume from last step
if [ "$LAST_STEP" == "REBOOT_REQUIRED" ]; then
    echo "🔄 Resuming installation after reboot..."
    LAST_STEP=2
fi

# Ensure swap size is adequate
if [ "$LAST_STEP" -lt 1 ]; then
    echo "📌 Setting up swap space..."
    sudo fallocate -l 1G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    sudo bash -c 'echo "/swapfile none swap sw 0 0" >> /etc/fstab'
    log_progress "1"
    sudo reboot
fi

# Step 1: Install Wyoming Satellite
if [ "$LAST_STEP" -lt 2 ]; then
    echo "📌 Installing Wyoming Satellite..."
    sudo apt update -y
    sudo apt install -y python3 python3-venv python3-pip git

    if [ ! -d "$HOME/wyoming-satellite" ]; then
        git clone https://github.com/rhasspy/wyoming-satellite.git ~/wyoming-satellite
    fi
    cd ~/wyoming-satellite || exit
    python3 -m venv venv
    source venv/bin/activate
    pip install -r requirements.txt
    pip install boost
    export BOOST_INCLUDEDIR=/usr/include/boost
    deactivate
    log_progress "2"
    sudo reboot
fi

# Step 2: Install PulseAudio
if [ "$LAST_STEP" -lt 3 ]; then
    echo "📌 Installing PulseAudio and dependencies..."
    sudo apt install -y pulseaudio pulseaudio-utils git wget curl alsa-utils jq libasound2 avahi-daemon libboost-all-dev
    log_progress "3"
    sudo reboot
fi

# Step 3: Install Wyoming Enhancements
if [ "$LAST_STEP" -lt 4 ]; then
    echo "📌 Installing Wyoming Enhancements..."
    if [ ! -d "$HOME/wyoming-enhancements" ]; then
        git clone https://github.com/FutureProofHomes/wyoming-enhancements.git ~/wyoming-enhancements
    fi
    log_progress "4"
    sudo reboot
fi

# Step 4: Install Snapclient
if [ "$LAST_STEP" -lt 5 ]; then
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
    log_progress "5"
    sudo reboot
fi

# Step 5: Modify Wyoming Satellite
if [ "$LAST_STEP" -lt 6 ]; then
    echo "📌 Modifying Wyoming Satellite..."
    MODIFY_WYOMING_SCRIPT="$HOME/wyoming-enhancements/snapcast/modify_wyoming_satellite.sh"
    if [ -f "$MODIFY_WYOMING_SCRIPT" ]; then
        bash "$MODIFY_WYOMING_SCRIPT"
    fi
    sudo systemctl restart wyoming-satellite
    log_progress "6"
fi

# Create systemd service to resume after reboot
if [ "$LAST_STEP" -lt 7 ]; then
    echo "📌 Creating systemd service for auto-resume..."

    SERVICE_FILE="/etc/systemd/system/ssv-setup-resume.service"
    sudo bash -c "cat <<EOL > $SERVICE_FILE
[Unit]
Description=Resume SSV Setup Script After Reboot
After=network.target

[Service]
ExecStart=/bin/bash /home/$USERNAME/SSV-Setup/setup_ssv.sh --resume
Restart=on-failure
User=$USERNAME

[Install]
WantedBy=multi-user.target
EOL"

    sudo systemctl daemon-reload
    sudo systemctl enable ssv-setup-resume
    log_progress "7"
fi

echo "===== SSV Setup Completed Successfully on $(date) ====="
