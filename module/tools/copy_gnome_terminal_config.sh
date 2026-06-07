dconf dump /org/gnome/terminal/ > gnome-terminal-backup.conf


dconf load /org/gnome/terminal/ < gnome-terminal-backup.conf
