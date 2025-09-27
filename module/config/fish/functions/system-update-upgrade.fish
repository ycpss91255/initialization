function system-update-upgrade --description 'Update, upgrade and clean up the system'
    if ! sudo apt update
        printf "sudo apt update failed.\n"
        return 1
    end

    if ! sudo apt upgrade -y
        printf "sudo apt upgrade failed.\n"
        return 1
    end

    if ! sudo apt autoremove -y
        printf "sudo apt autoremove failed.\n"
        return 1
    end

    if ! sudo apt autoclean
        printf "sudo apt autoclean failed.\n"
        return 1
    end
end
