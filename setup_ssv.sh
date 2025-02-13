#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# SSV One-Shot Installer Script
# This script installs and configures the SSV environment on a clean Raspberry Pi.
# It replicates the working SSV2 configuration.
# -----------------------------------------------------------------------------

# Determine the original user's home directory if running via sudo
if [ -n "${SUDO_USER:-}" ]; then
    USER_HOME=$(eval echo "~$SUDO_USER")
else
    USER_HOME="$HOME"
fi

# Set up logging in the original user's home directory
LOG_FILE="$USER_HOME/ssv_setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== SSV Setup Script Started on $(date) ====="

# Set USERNAME (use SUDO_USER if available)
USERNAME="${SUDO_USER:-$(whoami)}"
SSV_REPO_DIR="$HOME/wyoming-satellite"

# -----------------------------------------------------------------------------
# Function: load_configuration
# Description: Ensures that a configuration file exists and is loaded.
# -----------------------------------------------------------------------------
load_configuration() {
    CONFIG_FILE="$USER_HOME/ssv_config.cfg"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Configuration file not found. Creating default configuration at $CONFIG_FILE..."
        cat <<EOL > "$CONFIG_FILE"
SWAP_SIZE="2G"
ARECORD_DEVICE="plughw:CARD=seeed2micvoicec,DEV=0"
APLAY_DEVICE="plughw:CARD=seeed2micvoicec,DEV=0"
SNAPCLIENT_HOSTNAME="$(hostname)"
EOL
        echo "Default configuration file created."
    fi
    source "$CONFIG_FILE"
    echo "Loaded configuration:"
    echo "  SWAP_SIZE: $SWAP_SIZE"
    echo "  ARECORD_DEVICE: ${ARECORD_DEVICE:-plughw:CARD=seeed2micvoicec,DEV=0}"
    echo "  APLAY_DEVICE: ${APLAY_DEVICE:-plughw:CARD=seeed2micvoicec,DEV=0}"
    echo "  SNAPCLIENT_HOSTNAME: $SNAPCLIENT_HOSTNAME"
}

# -----------------------------------------------------------------------------
# Function: setup_swap
# Description: Creates a swap file if it does not exist.
# -----------------------------------------------------------------------------
setup_swap() {
    echo "===== Setting up swap ====="
    if [ ! -f "/swapfile" ]; then
        echo "Creating swap file of size $SWAP_SIZE..."
        sudo fallocate -l "$SWAP_SIZE" /swapfile
        sudo chmod 600 /swapfile
        sudo mkswap /swapfile
        sudo swapon /swapfile
        if ! grep -q "/swapfile" /etc/fstab; then
            sudo bash -c 'echo "/swapfile none swap sw 0 0" >> /etc/fstab'
        fi
    else
        echo "Swap file already exists; skipping creation."
    fi
}

# -----------------------------------------------------------------------------
# Function: install_system_packages
# Description: Updates the system and installs required Debian packages.
# -----------------------------------------------------------------------------
install_system_packages() {
    echo "===== Installing system packages ====="
    sudo apt update -y
    sudo apt upgrade -y
    sudo apt install -y python3 python3-venv python3-pip portaudio19-dev flac git wget curl alsa-utils pulseaudio pulseaudio-utils jq libasound2 avahi-daemon libboost-all-dev
}

# -----------------------------------------------------------------------------
# Function: clone_repositories
# Description: Clones the required repositories if they are not already present.
# -----------------------------------------------------------------------------
clone_repositories() {
    echo "===== Cloning Repositories ====="
    if [ ! -d "$SSV_REPO_DIR" ]; then
        echo "Cloning Wyoming Satellite repository..."
        git clone https://github.com/rhasspy/wyoming-satellite.git "$SSV_REPO_DIR"
    else
        echo "Wyoming Satellite repository already exists; skipping clone."
    fi

    if [ ! -d "$HOME/wyoming-openwakeword" ]; then
        echo "Cloning Wyoming OpenWakeWord repository..."
        git clone https://github.com/rhasspy/wyoming-openwakeword.git "$HOME/wyoming-openwakeword"
    else
        echo "Wyoming OpenWakeWord repository already exists; skipping clone."
    fi

    if [ ! -d "$HOME/wyoming-enhancements" ]; then
        echo "Cloning Wyoming Enhancements repository..."
        git clone https://github.com/FutureProofHomes/wyoming-enhancements.git "$HOME/wyoming-enhancements"
    else
        echo "Wyoming Enhancements repository already exists; skipping clone."
    fi
}

# -----------------------------------------------------------------------------
# Function: install_wyoming_satellite
# Description: Installs dependencies for Wyoming Satellite if a requirements file exists.
# -----------------------------------------------------------------------------
install_wyoming_satellite() {
    echo "===== Installing Wyoming Satellite ====="
    cd "$SSV_REPO_DIR" || { echo "Failed to change directory to $SSV_REPO_DIR"; exit 1; }
    if [ -f requirements.txt ]; then
        echo "Installing Python dependencies from requirements.txt..."
        pip install --break-system-packages -r requirements.txt
    else
        echo "requirements.txt not found, skipping dependency installation."
    fi
}

# -----------------------------------------------------------------------------
# Function: install_respeaker_drivers
# Description: Runs the external ReSpeaker drivers installation script.
# -----------------------------------------------------------------------------
install_respeaker_drivers() {
    echo "===== Installing ReSpeaker Drivers ====="
    if [ -d "$SSV_REPO_DIR" ]; then
        cd "$SSV_REPO_DIR" || { echo "Failed to change directory to $SSV_REPO_DIR"; exit 1; }
        sudo bash etc/install-respeaker-drivers.sh || echo "Warning: ReSpeaker driver installation encountered an error, but continuing..."
    else
        echo "Error: Wyoming Satellite repository not found at $SSV_REPO_DIR. Skipping ReSpeaker driver installation."
    fi
}

# -----------------------------------------------------------------------------
# Function: setup_virtualenv
# Description: Creates and configures the virtual environment for Wyoming Satellite.
# -----------------------------------------------------------------------------
setup_virtualenv() {
    echo "===== Creating Virtual Environment ====="
    cd "$SSV_REPO_DIR" || { echo "Failed to change directory to $SSV_REPO_DIR"; exit 1; }
    python3 -m venv --system-site-packages .venv
    echo "Activating virtual environment..."
    source .venv/bin/activate
    echo "Upgrading pip, wheel, and setuptools..."
    pip install --break-system-packages --upgrade pip wheel setuptools
    echo "Installing Python dependencies (including Wyoming Satellite)..."
    pip install --break-system-packages \
      -f 'https://synesthesiam.github.io/prebuilt-apps/' \
      -e '.[all]'
    echo "Testing run command..."
    script/run --help || echo "Warning: run command test failed"
    echo "Deactivating virtual environment..."
    deactivate
}

# -----------------------------------------------------------------------------
# Function: install_boost
# Description: Installs Boost in the virtual environment and sets BOOST_INCLUDEDIR.
# -----------------------------------------------------------------------------
install_boost() {
    echo "===== Installing Boost Manually ====="
    cd "$SSV_REPO_DIR" || exit 1
    source .venv/bin/activate
    pip install --break-system-packages boost
    export BOOST_INCLUDEDIR=/usr/include/boost
    echo "BOOST_INCLUDEDIR set to $BOOST_INCLUDEDIR"
    deactivate
}

# -----------------------------------------------------------------------------
# Function: configure_pulseaudio
# Description: Configures PulseAudio in system-wide mode.
# -----------------------------------------------------------------------------
configure_pulseaudio() {
    echo "===== Configuring PulseAudio in system-wide mode ====="
    sudo apt install -y pulseaudio pulseaudio-utils
    sudo tee /etc/pulse/system.pa <<EOL
#!/usr/bin/pulseaudio -nF
load-module module-device-restore
load-module module-stream-restore
load-module module-card-restore
.ifexists module-udev-detect.so
load-module module-udev-detect
.else
load-module module-detect
.endif
.ifexists module-esound-protocol-unix.so
load-module module-esound-protocol-unix
.endif
load-module module-native-protocol-unix
load-module module-default-device-restore
load-module module-always-sink
load-module module-suspend-on-idle
load-module module-position-event-sounds
.nofail
.include /etc/pulse/system.pa.d
load-module module-role-ducking trigger_roles=announce,phone,notification,event ducking_roles=any_role volume=33%
.ifexists module-alsa-sink.so
load-module module-alsa-sink device=hw:1,0 sink_name=seeed_sink
set-default-sink seeed_sink
.endif
EOL
    sudo chmod 644 /etc/pulse/system.pa
    sudo systemctl restart pulseaudio
}

# -----------------------------------------------------------------------------
# Function: install_snapclient
# Description: Installs and configures Snapclient.
# -----------------------------------------------------------------------------
install_snapclient() {
    echo "===== Installing Snapclient ====="
    SNAP_VERSION="0.31.0"
    SNAP_URL="https://github.com/badaix/snapcast/releases/download/v${SNAP_VERSION}/snapclient_${SNAP_VERSION}-1_armhf_bookworm_with-pulse.deb"
    if ! command -v snapclient &> /dev/null; then
        echo "Downloading and installing Snapclient..."
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
    SNAPCAST_CONFIG="/etc/default/snapclient"
    sudo tee "$SNAPCAST_CONFIG" <<EOL
SNAPCLIENT_OPTS="-h localhost -s ${SNAPCLIENT_HOSTNAME:-$USERNAME}"
EOL
    sudo systemctl restart snapclient
}

# -----------------------------------------------------------------------------
# Function: apply_wyoming_enhancements
# Description: Applies modifications from the Wyoming Enhancements repository.
# -----------------------------------------------------------------------------
apply_wyoming_enhancements() {
    echo "===== Applying Wyoming Enhancements ====="
    if [ ! -d "$HOME/wyoming-enhancements" ]; then
        echo "Cloning Wyoming Enhancements repository..."
        git clone https://github.com/FutureProofHomes/wyoming-enhancements.git "$HOME/wyoming-enhancements"
    fi

SERVICE_FILE="/etc/systemd/system/enhanced-wyoming-satellite.service"
sudo rm -f "$SERVICE_FILE"
cat <<EOL | sudo tee "$SERVICE_FILE"
[Unit]
Description=Enhanced Wyoming Satellite
Wants=network-online.target
After=network-online.target
Requires=wyoming-openwakeword.service
Requires=2mic_leds.service
Requires=pulseaudio.service

[Service]
Type=simple
ExecStart=/home/$USERNAME/wyoming-satellite/script/run \
  --name '$USERNAME' \
  --uri 'tcp://0.0.0.0:10700' \
  --mic-command 'parecord --property=media.role=phone --rate=16000 --channels=1 --format=s16le --raw --latency-msec 10' \
  --snd-command 'paplay --property=media.role=announce --rate=44100 --channels=1 --format=s16le --raw --latency-msec 10' \
  --snd-command-rate 44100 \
  --snd-volume-multiplier 0.1 \
  --mic-auto-gain 7 \
  --mic-noise-suppression 3 \
  --wake-uri 'tcp://127.0.0.1:10400' \
  --wake-word-name 'hey_jarvis' \
  --event-uri 'tcp://127.0.0.1:10500'
  --detection-command '/home/$USERNAME/wyoming-enhancements/snapcast/scripts/awake.sh' \
  --tts-stop-command '/home/$USERNAME/wyoming-enhancements/snapcast/scripts/done.sh' \
  --error-command '/home/$USERNAME/wyoming-enhancements/snapcast/scripts/done.sh' \
  --awake-wav sounds/awake.wav \
  --done-wav sounds/done.wav
WorkingDirectory=/home/$USERNAME/wyoming-satellite
Restart=always
RestartSec=1
#User=$USERNAME
[Install]
WantedBy=default.target

EOL

    MODIFY_WYOMING_SCRIPT="$HOME/wyoming-enhancements/snapcast/modify_wyoming_satellite.sh"
    if [ -f "$MODIFY_WYOMING_SCRIPT" ]; then
        echo "Applying modifications via Wyoming Enhancements..."
        bash "$MODIFY_WYOMING_SCRIPT"
    else
        echo "Modification script not found; skipping enhancements."
    fi
  sudo systemctl enable --now enhanced-wyoming-satellite.service  
 # sudo systemctl restart wyoming-satellite
}

# -----------------------------------------------------------------------------
# Function: create_systemd_service
# Description: Creates and enables the Wyoming Satellite systemd service.
# -----------------------------------------------------------------------------
create_systemd_service() {
    echo "===== Creating the Systemd Service ====="
    SERVICE_FILE="/etc/systemd/system/wyoming-satellite.service"
    sudo rm -f "$SERVICE_FILE"
    sudo tee "$SERVICE_FILE" <<EOL
[Unit]
Description=Wyoming Satellite
Wants=network-online.target
After=network-online.target
Requires=wyoming-openwakeword.service
Requires=2mic_leds.service

[Service]
Type=simple
ExecStart=/home/$USERNAME/wyoming-satellite/script/run \\
  --name '$USERNAME' \\
  --uri 'tcp://0.0.0.0:10700' \\
  --mic-command "arecord -D \${ARECORD_DEVICE:-plughw:CARD=seeed2micvoicec,DEV=0} -r 16000 -c 1 -f S16_LE -t raw" \\
  --snd-command "aplay -D \${APLAY_DEVICE:-plughw:CARD=seeed2micvoicec,DEV=0} -r 22050 -c 1 -f S16_LE -t raw" \\
  --wake-uri 'tcp://127.0.0.1:10400' \\
  --wake-word-name 'hey_jarvis' \\
  --event-uri 'tcp://127.0.0.1:10500'
WorkingDirectory=/home/$USERNAME/wyoming-satellite
Restart=always
RestartSec=1
User=$USERNAME

[Install]
WantedBy=default.target
EOL
    sudo systemctl daemon-reload
    sudo systemctl enable wyoming-satellite
    sudo systemctl restart wyoming-satellite
}


install_led_service() {
  echo "===== Setting up LED service for ReSpeaker 2-Mic HAT ====="

  cd "$HOME/wyoming-satellite/examples" || exit

  # Create a Python virtual environment for the LED service
  python3 -m venv --system-site-packages .venv
  .venv/bin/pip3 install --upgrade pip wheel setuptools
  .venv/bin/pip3 install 'wyoming==1.5.2'

  # Install additional dependencies for LED control
  sudo apt-get install -y python3-spidev python3-gpiozero

  # Test the LED service script
  .venv/bin/python3 2mic_service.py --help

  # Remove any existing systemd service file for LED service
  LED_SERVICE_FILE="/etc/systemd/system/2mic_leds.service"
  if [ -f "$LED_SERVICE_FILE" ]; then
    sudo rm "$LED_SERVICE_FILE"
  fi

  cat <<EOL | sudo tee "$LED_SERVICE_FILE"
[Unit]
Description=2Mic LEDs
[Service]
Type=simple
ExecStart=$HOME/wyoming-satellite/examples/.venv/bin/python3 2mic_service.py --uri 'tcp://127.0.0.1:10500'
WorkingDirectory=$HOME/wyoming-satellite/examples
Restart=always
RestartSec=1
[Install]
WantedBy=default.target
EOL

  sudo systemctl daemon-reload
  sudo systemctl enable 2mic_leds.service
 # sudo systemctl restart 2mic_leds.service

  echo "===== LED Service Setup Complete ====="
}

install_wakeword() {
  echo "===== Installing local wake word detection (openWakeWord) ====="

  # Install dependencies for openWakeWord
  sudo apt-get update
  sudo apt-get install --no-install-recommends -y libopenblas-dev

  # Clone the repository if not present
  if [ ! -d "$HOME/wyoming-openwakeword" ]; then
    git clone https://github.com/rhasspy/wyoming-openwakeword.git "$HOME/wyoming-openwakeword"
  fi

  cd "$HOME/wyoming-openwakeword" || exit
  script/setup

  # Create or update the systemd service file for openWakeWord
  WAKEWORD_SERVICE_FILE="/etc/systemd/system/wyoming-openwakeword.service"
  if [ -f "$WAKEWORD_SERVICE_FILE" ]; then
    sudo rm "$WAKEWORD_SERVICE_FILE"
  fi

  cat <<EOL | sudo tee "$WAKEWORD_SERVICE_FILE"
[Unit]
Description=Wyoming openWakeWord
[Service]
Type=simple
ExecStart=$HOME/wyoming-openwakeword/script/run --uri 'tcp://127.0.0.1:10400'
WorkingDirectory=$HOME/wyoming-openwakeword
Restart=always
RestartSec=1
[Install]
WantedBy=default.target
EOL

  sudo systemctl daemon-reload
  sudo systemctl enable wyoming-openwakeword
 # sudo systemctl restart wyoming-openwakeword

  echo "===== openWakeWord Installation Complete ====="
}


# -----------------------------------------------------------------------------
# Main routine: Calls all functions in sequence.
# -----------------------------------------------------------------------------
main() {
    load_configuration
    install_system_packages
    setup_swap
    clone_repositories
    install_wyoming_satellite
    install_wakeword
    install_respeaker_drivers
    setup_virtualenv
    install_boost
    configure_pulseaudio
    install_led_service
    install_snapclient
    apply_wyoming_enhancements
    create_systemd_service
    echo "===== SSV Setup Completed Successfully on $(date) ====="
}

# Execute the main routine
main
