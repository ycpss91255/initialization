#!/usr/bin/env bash

# 設定時區
sudo timedatectl set-timezone Asia/Taipei

# 安裝 ntpdate
sudo apt-get update
sudo apt-get install -y ntpdate

# 與 NTP server 對時
sudo ntpdate tw.pool.ntp.org

# 把系統時間寫入硬體時鐘
sudo hwclock --localtime --systohc
