#!/bin/bash

set -e  # Stop the script on any errors

echo "Starting setup for Snapcast, PulseAudio, Wyoming Satellite, and Enhancements on $(hostname)..."

### STEP 1: Increase Swap Size to Prevent Build Failures ###
SWAP_FILE="/swapfile"
if [ ! -f "$SWAP_FILE" ]; then
    echo "Increasing swap size to 2GB..."
    sudo fallocate -l 2G $SWAP_FILE
    sudo chmod 600 $SWAP_FILE
    sudo mkswap $SWAP_FILE
    sudo swapon $SWAP_FILE
    echo "$SWAP_FILE none swap sw 0 0" | sudo tee -a /etc/fstab
else
    echo "Swap file already exists."
fi

### STEP 2: Install Required Dependencies ###
echo "Installing dependencies..."
sudo apt update
sudo apt install -y \
    pulseaudio pulseaudio-utils \
    snapclient \
    python3 python3-pip python3-venv \
    libasound2 libasound2-plugins \
    avahi-daemon \
    git wget curl jq

### STEP 3: Set Up PulseAudio in System Mode ###
echo "Configuring PulseAudio in system mode..."
sudo systemctl stop pulseaudio
sudo systemctl disable pulseaudio
sudo systemctl mask pulseaudio

# Create PulseAudio system service
cat <<EOF | sudo tee /etc/systemd/system/pulseaudio.service
[Unit]
Description=PulseAudio Sound System (System Mode)
Requires=avahi-daemon.service
After=avahi-daemon.service

[Service]
ExecStart=/usr/bin/pulseaudio --system --disallow-exit --disallow-module-loading --daemonize=no --log-target=journal
Restart=always
User=pulse
Group=pulse
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# Enable PulseAudio service
sudo systemctl daemon-reload
sudo systemctl enable pulseaudio.service
sudo systemctl restart pulseaudio.service

# Configure PulseAudio system.pa
PULSE_CONF="/etc/pulse/system.pa"
if ! grep -q "seeed_sink" "$PULSE_CONF"; then
    echo "Updating PulseAudio configuration..."
    sudo bash -c "cat <<EOL >> $PULSE_CONF

### Custom PulseAudio Configuration for Seeed VoiceCard ###
load-module module-alsa-sink device=hw:1,0 sink_name=seeed_sink
set-default-sink seeed_sink
EOL"
fi

### STEP 4: Set Up Snapcast Client ###
echo "Configuring Snapcast client..."
sudo systemctl stop snapclient
sudo systemctl disable snapclient

# Create Snapclient systemd service
cat <<EOF | sudo tee /etc/systemd/system/snapclient.service
[Unit]
Description=Snapcast Client
After=pulseaudio.service
Requires=pulseaudio.service

[Service]
ExecStart=/usr/bin/snapclient --player pulse
Restart=always
User=snapclient
Group=snapclient
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# Enable Snapclient service
sudo systemctl daemon-reload
sudo systemctl enable snapclient.service
sudo systemctl restart snapclient.service

### STEP 5: Install Wyoming Satellite ###
echo "Installing Wyoming Satellite..."
WYOMING_DIR="/opt/wyoming"
if [ ! -d "$WYOMING_DIR" ]; then
    sudo mkdir -p "$WYOMING_DIR"
    cd "$WYOMING_DIR"
    sudo git clone https://github.com/rhasspy/wyoming-satellite.git .
    python3 -m venv venv
    source venv/bin/activate
    pip install -r requirements.txt
    deactivate
fi

# Create Wyoming Satellite systemd service
cat <<EOF | sudo tee /etc/systemd/system/wyoming-satellite.service
[Unit]
Description=Wyoming Satellite
After=network.target

[Service]
ExecStart=$WYOMING_DIR/venv/bin/python3 $WYOMING_DIR/satellite.py
WorkingDirectory=$WYOMING_DIR
Restart=always
User=pi
Group=pi

[Install]
WantedBy=multi-user.target
EOF

# Enable Wyoming Satellite service
sudo systemctl daemon-reload
sudo systemctl enable wyoming-satellite.service
sudo systemctl restart wyoming-satellite.service

### STEP 6: Install Wyoming Enhancements ###
echo "Installing Wyoming Enhancements..."
ENHANCEMENTS_DIR="/opt/wyoming-enhancements"
if [ ! -d "$ENHANCEMENTS_DIR" ]; then
    sudo mkdir -p "$ENHANCEMENTS_DIR"
    cd "$ENHANCEMENTS_DIR"
    sudo git clone https://github.com/your-repo/wyoming-enhancements.git .  # Replace with actual repo if needed
    python3 -m venv venv
    source venv/bin/activate
    pip install -r requirements.txt
    deactivate
fi

# Create Wyoming Enhancements systemd service
cat <<EOF | sudo tee /etc/systemd/system/wyoming-enhancements.service
[Unit]
Description=Wyoming Enhancements
After=wyoming-satellite.service
Requires=wyoming-satellite.service

[Service]
ExecStart=$ENHANCEMENTS_DIR/venv/bin/python3 $ENHANCEMENTS_DIR/enhancements.py
WorkingDirectory=$ENHANCEMENTS_DIR
Restart=always
User=pi
Group=pi

[Install]
WantedBy=multi-user.target
EOF

# Enable Wyoming Enhancements service
sudo systemctl daemon-reload
sudo systemctl enable wyoming-enhancements.service
sudo systemctl restart wyoming-enhancements.service

### STEP 7: Clean Up ###
echo "Cleaning up..."
sudo apt autoremove -y
sudo apt clean

echo "Setup complete! Reboot your system to finalize the installation."
