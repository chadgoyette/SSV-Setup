#!/bin/bash
set -euo pipefail
echo "===== SSV Setup Script Started on $(date) ====="

echo "===== Load or Create Config File  ====="
# Set this variable in your configuration (or here) to the expected repository directory.
SSV_REPO_DIR="/home/$(whoami)/wyoming-satellite"


load_configuration() {
  CONFIG_FILE="$HOME/ssv_config.cfg"
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
  echo "  ARECORD_DEVICE: $ARECORD_DEVICE"
  echo "  APLAY_DEVICE: $APLAY_DEVICE"
  echo "  SNAPCLIENT_HOSTNAME: $SNAPCLIENT_HOSTNAME"
}


HOSTNAME=$(hostname)
USERNAME=$(whoami)
# Determine the proper home directory for logs.
if [ -n "${SUDO_USER:-}" ]; then
    # If run with sudo, get the home directory of the original user.
    USER_HOME=$(eval echo "~$SUDO_USER")
else
    USER_HOME=$HOME
fi

# Set the log file in the original user's home directory.
LOG_FILE="$USER_HOME/ssv_setup.log"

# Redirect stdout and stderr to the log file (append mode)
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== SSV Setup Script Started on $(date) ====="

# Update package lists and upgrade system
sudo apt update -y
sudo apt upgrade -y

echo "===== Swap Function  ====="

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

# Step 1: Clone Necessary Repositories
echo "===== Cloning Necessary Repositories ====="

# Define repositories and their target directories
declare -A REPOS=(
    ["https://github.com/rhasspy/wyoming-openwakeword.git"]="$HOME/wyoming-openwakeword"
    ["https://github.com/FutureProofHomes/wyoming-enhancements.git"]="$HOME/wyoming-enhancements"
)

# Clone repositories if they don't already exist
for REPO_URL in "${!REPOS[@]}"; {
    TARGET_DIR="${REPOS[$REPO_URL]}"
    if [ ! -d "$TARGET_DIR" ]; then
        echo "Cloning $REPO_URL into $TARGET_DIR..."
        git clone "$REPO_URL" "$TARGET_DIR"
    else
        echo "Repository $REPO_URL already cloned in $TARGET_DIR."
    fi
}


# Step 1: Install Wyoming Satellite (Following the Official Tutorial)
echo "===== Running Wyoming Satellite Function ====="
install_wyoming_satellite() {
  echo "===== Installing Wyoming Satellite ====="
  
  # Ensure dependencies are installed
  sudo apt install -y python3 python3-venv python3-pip portaudio19-dev flac

  # Clone the Wyoming Satellite repository if not present
  if [ ! -d "$HOME/wyoming-satellite" ]; then
    echo "Cloning Wyoming Satellite repository..."
    git clone https://github.com/rhasspy/wyoming-satellite.git ~/wyoming-satellite
  fi

  cd ~/wyoming-satellite || exit

  # Remove virtual environment if owned by root
  if [ -d "$HOME/wyoming-satellite/.venv" ]; then
    OWNER=$(stat -c '%U' "$HOME/wyoming-satellite/.venv")
    if [ "$OWNER" != "$(whoami)" ]; then
      echo "Removing .venv due to incorrect ownership..."
      sudo rm -rf "$HOME/wyoming-satellite/.venv"
    fi
  fi

  # Create a new Python virtual environment
  echo "Creating a new Python virtual environment..."
  python3 -m venv .venv
  source .venv/bin/activate

  # Install dependencies
  echo "Installing Wyoming Satellite dependencies..."
  pip install --upgrade pip
  pip install -r requirements.txt
  deactivate

  # Install Boost manually
  pip install boost
  export BOOST_INCLUDEDIR=/usr/include/boost

  # Install additional dependencies for ReSpeaker 2-Mic HAT
  pip install pyaudio numpy

  # Create the configuration file for Wyoming Satellite
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

  # Create or update the systemd service for Wyoming Satellite
  SERVICE_FILE="/etc/systemd/system/wyoming-satellite.service"
  if [ -f "$SERVICE_FILE" ]; then
    sudo rm "$SERVICE_FILE"
  fi

  cat <<EOL | sudo tee "$SERVICE_FILE"
[Unit]
Description=Wyoming Satellite
Wants=network-online.target
After=network-online.target
Requires=wyoming-openwakeword.service
Requires=2mic_leds.service
[Service]
Type=simple
ExecStart=/home/$(whoami)/wyoming-satellite/script/run \
 --name '$(whoami)' \
 --uri 'tcp://0.0.0.0:10700' \
 --mic-command "arecord -D $ARECORD_DEVICE -r 16000 -c 1 -f S16_LE -t raw" \
 --snd-command "aplay -D $APLAY_DEVICE -r 22050 -c 1 -f S16_LE -t raw" \
 --wake-uri 'tcp://127.0.0.1:10400' \
 --wake-word-name 'hey_jarvis' \
 --event-uri 'tcp://127.0.0.1:10500'
WorkingDirectory=/home/$(whoami)/wyoming-satellite
Restart=always
RestartSec=1
User=$(whoami)
[Install]
WantedBy=default.target
EOL

  sudo systemctl daemon-reload
  sudo systemctl enable wyoming-satellite
  sudo systemctl restart wyoming-satellite

  echo "===== Wyoming Satellite Installation Complete ====="
}



# Install ReSpeaker drivers (inside Wyoming Satellite directory)
echo "===== Installing ReSpeaker Drivers ====="
echo "===== Installing ReSpeaker Drivers ====="
if [ -d "$SSV_REPO_DIR" ]; then
    cd "$SSV_REPO_DIR" || { echo "Failed to change directory to $SSV_REPO_DIR"; exit 1; }
    sudo bash etc/install-respeaker-drivers.sh || echo "Warning: ReSpeaker driver installation encountered an error, but continuing..."
else
    echo "Error: Wyoming Satellite repository not found at $SSV_REPO_DIR. Skipping ReSpeaker driver installation."
fi
python3 -m venv .venv
.venv/bin/pip3 install --upgrade pip
.venv/bin/pip3 install --upgrade wheel setuptools
.venv/bin/pip3 install \
  -f 'https://synesthesiam.github.io/prebuilt-apps/' \
  -e '.[all]'
script/run --help

# Deactivate the virtual environment
#deactivate


echo "===== Starting system site package VM ====="
python3 -m venv --system-site-packages .venv
echo "===== Installing Boost Manually ====="

# Install Boost manually to avoid header path issues
pip install boost
BOOST_INCLUDEDIR=/usr/include/boost
export BOOST_INCLUDEDIR

echo "===== Installing pyaudio numpy for ReSpeaker 2-Mic HAT ====="

# Install additional dependencies for ReSpeaker 2-Mic HAT
pip install pyaudio numpy

echo "===== Deactivate the Virtual Environment ====="

# Deactivate the virtual environment
deactivate

echo "===== Creating the Wyoming Satellite Config FIle ====="

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

echo "===== If the file exists removing ====="

# Remove existing Wyoming Satellite service file if it exists
SERVICE_FILE="/etc/systemd/system/wyoming-satellite.service"
if [ -f "$SERVICE_FILE" ]; then
    sudo rm "$SERVICE_FILE"
fi

echo "===== Creating the Systemd Service ====="

# Create Wyoming Satellite Systemd Service
SERVICE_FILE="/etc/systemd/system/wyoming-satellite.service"
sudo rm -f "$SERVICE_FILE"
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
  --mic-command "arecord -D $ARECORD_DEVICE -r 16000 -c 1 -f S16_LE -t raw" \
  --snd-command "aplay -D $APLAY_DEVICE -r 22050 -c 1 -f S16_LE -t raw" \
  --wake-uri 'tcp://127.0.0.1:10400' \
  --wake-word-name 'hey_jarvis' \
  --event-uri 'tcp://127.0.0.1:10500'
WorkingDirectory=/home/$USERNAME/wyoming-satellite
Restart=always
RestartSec=1
User=$USERNAME

[Install]
WantedBy=default.target
EOL

echo "===== Installing Local Wake Word Detection ====="

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
  sudo systemctl restart wyoming-openwakeword

  echo "===== openWakeWord Installation Complete ====="
}

echo "===== Configuring the LED Service ====="

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
  sudo systemctl restart 2mic_leds.service

  echo "===== LED Service Setup Complete ====="
}


echo "===== Reloading the WYoming-Satellite Service ====="

# Reload systemd and restart the service
sudo systemctl daemon-reload
sudo systemctl enable wyoming-satellite
sudo systemctl restart wyoming-satellite

echo "===== Wyoming Satellite Installation Complete ====="

echo "===== Starting PulseAudio Installation ======="

# Stop Wyoming Satellite and LED services before modifying PulseAudio
sudo systemctl stop wyoming-satellite || true
sudo systemctl stop 2mic_leds.service || true

echo "===== Stoping Wyoming Service for PulseAudio Installation ======="


configure_pulseaudio() {
  echo "===== Configuring PulseAudio in system-wide mode ====="
  sudo apt install -y pulseaudio pulseaudio-utils git wget curl alsa-utils python3-pip jq libasound2 avahi-daemon libboost-all-dev
  sudo groupadd -r pulse || true
  sudo useradd -r -g pulse -G audio -d /var/run/pulse pulse || true
  sudo usermod -aG pulse-access "$(whoami)"

  sudo mkdir -p /etc/pulse
  sudo tee /etc/pulse/system.pa <<EOL
#!/usr/bin/pulseaudio -nF
load-module module-native-protocol-unix
load-module module-udev-detect
load-module module-alsa-sink device=hw:1,0 sink_name=seeed_sink
load-module module-always-sink
EOL
  sudo chmod 644 /etc/pulse/system.pa
  sudo systemctl restart pulseaudio

  echo "===== PulseAudio Configuration Complete ====="
}

echo "===== Setting Permissions and Restarting PA ======="
# Set permissions and restart PulseAudio
sudo chmod 644 /etc/pulse/system.pa
sudo systemctl restart pulseaudio


echo "=====************************************************* Testing Audio ******************************************************** ======="
paplay /usr/share/sounds/alsa/Front_Center.wav
echo "=====************************************************* Testing Audio Complete************************************************ ======="

echo "===== Configuring PulseAudio Volume Ducking ====="

# Ensure PulseAudio system.pa file exists
sudo touch /etc/pulse/system.pa

# Check if the module is already in the file
if ! grep -q "module-role-ducking" /etc/pulse/system.pa; then
    echo "Adding module-role-ducking to PulseAudio configuration..."
    sudo tee -a /etc/pulse/system.pa > /dev/null <<EOL

### Enable Volume Ducking
load-module module-role-ducking trigger_roles=announce,phone,notification,event ducking_roles=any_role volume=33%
EOL
else
    echo "PulseAudio volume ducking module is already configured."
fi

# Restart PulseAudio to apply changes
sudo systemctl daemon-reload
sudo systemctl restart pulseaudio.service

echo "✅ PulseAudio volume ducking configured successfully."

echo "===== Installing Wyoming-Enhancements ======="
echo "===== Are you Bored Yet??????  ======="
# Step 3: Install Wyoming Enhancements
if [ ! -d "$HOME/wyoming-enhancements" ]; then
    echo "Cloning Wyoming Enhancements repository..."
    git clone https://github.com/FutureProofHomes/wyoming-enhancements.git ~/wyoming-enhancements
fi

echo "===== Installing Snapcast Client...This will be fun! ======="
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

  # Configure Snapclient to use the correct hostname
  SNAPCAST_CONFIG="/etc/default/snapclient"
  cat <<EOL | sudo tee "$SNAPCAST_CONFIG"
SNAPCLIENT_OPTS="-h localhost -s $SNAPCLIENT_HOSTNAME"
EOL
  sudo systemctl restart snapclient

  echo "===== Snapclient Installation Complete ====="
}


echo "===== Applying the Wyoming Enhancements ======="
apply_wyoming_enhancements() {
  echo "===== Applying Wyoming Enhancements ====="
  
  if [ ! -d "$HOME/wyoming-enhancements" ]; then
    echo "Cloning Wyoming Enhancements repository..."
    git clone https://github.com/FutureProofHomes/wyoming-enhancements.git "$HOME/wyoming-enhancements"
  fi

  MODIFY_WYOMING_SCRIPT="$HOME/wyoming-enhancements/snapcast/modify_wyoming_satellite.sh"
  if [ -f "$MODIFY_WYOMING_SCRIPT" ]; then
    echo "Applying modifications via Wyoming Enhancements..."
    bash "$MODIFY_WYOMING_SCRIPT"
  else
    echo "Modification script not found; skipping enhancements."
  fi

  sudo systemctl restart wyoming-satellite
  echo "===== Wyoming Enhancements Applied ====="
}

echo "===== SSV Setup Completed Successfully on $(date) ====="



main() {
  echo "===== SSV Setup Script Started on $(date) ====="
  
  # Load configuration
  load_configuration
  
  # Setup swap file
  setup_swap
  
  # Install Wyoming Satellite
  install_wyoming_satellite
  
  # Configure PulseAudio
  configure_pulseaudio
  
  # (Call other functions here, e.g., install_wakeword, setup_led_service, install_snapclient, etc.)
  
  echo "===== SSV Setup Completed Successfully on $(date) ====="
}

# Execute main function
main
