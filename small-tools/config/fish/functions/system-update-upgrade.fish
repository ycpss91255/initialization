function system-update-upgrade --description 'Upgrading the system and removing old packages'
    sudo apt update &&
    sudo apt upgrade -y &&
    sudo apt autoremove -y &&
    sudo apt autoclean
end
