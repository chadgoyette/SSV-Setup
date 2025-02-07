#!/bin/bash

STATE_FILE="/tmp/setup_state"

function update_state {
    echo "$1" > "$STATE_FILE"
}

function get_state {
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
    else
        echo "0"
    fi
}

CURRENT_STATE=$(get_state)

### Step 1: Install Dependencies ###
if [ "$CURRENT_STATE" -lt 1 ]; then
    echo "Step 1: Installing dependencies..."
    sudo apt update && sudo apt upgrade -y
    sudo apt install -y snapclient pulseaudio pulseaudio-utils git
    
    update_state 1
    echo "Step 1 completed. Rebooting now..."
    sudo reboot
    exit 0
fi

### Step 2: Configure PulseAudio ###
if [ "$CURRENT_STATE" -lt 2 ]; then
    echo "Step 2: Configuring PulseAudio in system mode..."
    
    sudo cp /etc/pulse/system.pa /etc/pulse/system.pa.bak
    sudo bash -c 'echo "load-module module-alsa-sink device=hw:1,0 sink_name=seeed_sink" >> /etc/pulse/system.pa'
    sudo bash -c 'echo "set-default-sink seeed_sink" >> /etc/pulse/system.pa'

    update_state 2
    echo "Step 2 completed. Restarting PulseAudio..."
    sudo systemctl restart pulseaudio
fi

### Step 3: Setup Snapclient ###
if [ "$CURRENT_STATE" -lt 3 ]; then
    echo "Step 3: Configuring Snapcast Client..."
    
    sudo systemctl enable snapclient
    sudo systemctl restart snapclient

    update_state 3
    echo "Setup complete!"
fi
