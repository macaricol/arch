#!/bin/bash

# Script to install Modern Clock widget for KDE Plasma on Arch Linux
# Based on: https://github.com/Prayag2/kde_modernclock

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'  # No Color

echo -e "${GREEN}Starting Modern Clock widget installation...${NC}"

# Check if Plasma is installed
if ! pacman -Qs plasma-desktop > /dev/null; then
    echo -e "${YELLOW}KDE Plasma not detected. Installing plasma-desktop...${NC}"
    sudo pacman -S --noconfirm plasma-desktop
fi

# Detect Plasma version (5 or 6) for kpackagetool
PLASMA_VERSION=$(plasmashell --version | grep -oP 'Plasma \K[56]')
if [[ "$PLASMA_VERSION" == "6" ]]; then
    KPACKAGETOOL="kpackagetool6"
else
    KPACKAGETOOL="kpackagetool5"
fi
echo -e "${GREEN}Detected Plasma $PLASMA_VERSION. Using $KPACKAGETOOL.${NC}"

# Clone the repository
WIDGET_DIR="$HOME/.local/share/plasma/plasmoids/modernclock"
if [ -d "$WIDGET_DIR" ]; then
    echo -e "${YELLOW}Widget directory exists. Removing and recloning...${NC}"
    rm -rf "$WIDGET_DIR"
fi
echo -e "${GREEN}Cloning Modern Clock from GitHub...${NC}"
git clone https://github.com/Prayag2/kde_modernclock.git "$WIDGET_DIR"

# Install the plasmoid
echo -e "${GREEN}Installing widget with $KPACKAGETOOL...${NC}"
cd "$WIDGET_DIR"
"$KPACKAGETOOL" --install .

# Verify installation
if "$KPACKAGETOOL" --list | grep -q modernclock; then
    echo -e "${GREEN}Installation successful!${NC}"
else
    echo -e "${RED}Installation failed. Check logs with journalctl -xe.${NC}"
    exit 1
fi

# Optional: Refresh font cache (if using custom fonts like ttf-liberation)
fc-cache -fv

# Optional: Example configuration - Add to desktop (adjust as needed)
# This uses kwriteconfig6 to add a containment for the widget (Plasma 6)
if [[ "$PLASMA_VERSION" == "6" ]]; then
    echo -e "${YELLOW}Adding widget to desktop (example)...${NC}"
    kwriteconfig6 --file ~/.config/plasma-org.kde.plasma.desktop-appletsrc \
        --group Containments \
        --key lastScreen 0
    # Restart Plasma to apply
    kquitapp6 plasmashell && sleep 2 && kstart6 plasmashell &
else
    # Plasma 5 equivalent
    kquitapp5 plasmashell && sleep 2 && kstart5 plasmashell &
fi

echo -e "${GREEN}Done! Right-click your desktop > Add Widgets > Search 'Modern Clock' to place it.${NC}"
echo -e "${YELLOW}Customize via right-click > Configure Modern Clock.${NC}"
