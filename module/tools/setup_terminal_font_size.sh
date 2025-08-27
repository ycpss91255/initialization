#!/usr/bin/env bash

set -euo pipefail

read -r -p "font zise? (8x16, 16x32 ...) " FONTSIZE

FONTFACE="Fixed"
FONTSIZE=${FONTSIZE:-"16x32"}

sudo sed -i "s/^FONTFACE=.*/FONTFACE=\"$FONTFACE\"/" /etc/default/console-setup && \
sudo sed -i "s/^FONTSIZE=.*/FONTSIZE=\"$FONTSIZE\"/" /etc/default/console-setup && \
sudo setupcon

# manual setting
# sudo dpkg-reconfigure console-setup
