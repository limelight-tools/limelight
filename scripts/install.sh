#!/bin/bash

# Limelight Stealth Installer
# https://github.com/limelight-tools/Limelight
# Designed for macOS 15+

set -e

# --- Configuration ---
REPO="limelight-tools/limelight"
APP_NAME="Limelight.app"
BINARY_NAME="Limelight"
INSTALL_PATH="/Applications/$APP_NAME"

echo "-----------------------------------------------"
echo "   Limelight: Open-Source Screen Dimmer"
echo "-----------------------------------------------"

# --- 1. macOS 15 Check ---
OS_MAJOR_VERSION=$(sw_vers -productVersion | cut -d. -f1)
if [ "$OS_MAJOR_VERSION" -lt 15 ]; then
    echo "❌ Error: Limelight requires macOS 15 (Sequoia) or newer."
    echo "   Current version detected: $(sw_vers -productVersion)"
    exit 1
fi

# --- 2. Graceful Shutdown ---
# Kill any running instances to prevent "File in use" errors.
# '|| true' ensures the script continues if Limelight isn't running.
if pgrep -x "$BINARY_NAME" > /dev/null; then
    echo "Stopping existing Limelight process..."
    pkill -x "$BINARY_NAME" || true
    sleep 1 # Give the OS a second to release the file hooks
fi

# --- 3. Create Temporary Workspace ---
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
cd "$WORK_DIR"

# --- 4. Locate Latest Release ---
echo "🔍 Searching for the latest verified build..."
DOWNLOAD_URL=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" \
| grep "browser_download_url.*zip" \
| cut -d : -f 2,3 \
| tr -d \" | xargs)

if [ -z "$DOWNLOAD_URL" ]; then
    echo "❌ Error: Could not resolve the download URL from GitHub."
    exit 1
fi

# --- 5. Download and Authorize ---
echo "📥 Downloading..."
curl -fsSL -o Limelight.zip "$DOWNLOAD_URL"

echo "🔓 Authorizing unsigned build (clearing quarantine)..."
unzip -q Limelight.zip
xattr -cr "$APP_NAME"

# --- 6. Install ---
echo "🛡️  Installing to /Applications (Admin password required)..."
# We wrap both commands in a single sudo bash call
sudo bash -c "rm -rf '$INSTALL_PATH' && mv '$APP_NAME' /Applications/"

# --- 7. Permission Reset & Launch ---
echo "🧹 Clearing stale security permissions (if any)..."
# This ensures macOS treats this version as a new request for Accessibility
sudo tccutil reset Accessibility io.github.limelight-tools.limelight || true

echo "🚀 Launching Limelight..."
sleep 1
open -a Limelight

echo "-----------------------------------------------"
echo "✅ Installation Complete!"
echo "Limelight is now running in your Menu Bar."
echo "⚠️  ACTION REQUIRED:"
echo "   Because this is an unsigned beta, each release will require you to re-grant Accessibility permissions."
echo ""
echo "   1. A system prompt should appear shortly."
echo "   2. Click 'Open System Settings'."
echo "   3. Find Limelight and toggle the switch to ON."
echo "-----------------------------------------------"