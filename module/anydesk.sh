# 更新基本套件
sudo apt update
sudo apt install -y ca-certificates curl apt-transport-https gnupg

# 建立 keyring 資料夾
sudo install -m 0755 -d /etc/apt/keyrings

# 下載並轉換 GPG key（重點在 gpg --dearmor）
curl -fsSL https://keys.anydesk.com/repos/DEB-GPG-KEY \
  | sudo gpg --dearmor -o /etc/apt/keyrings/anydesk.gpg

# 設定讀取權限（否則 _apt 無法讀會報 NO_PUBKEY）
sudo chmod 0644 /etc/apt/keyrings/anydesk.gpg

# 新增 AnyDesk 軟體源
echo "deb [signed-by=/etc/apt/keyrings/anydesk.gpg] https://deb.anydesk.com all main" \
  | sudo tee /etc/apt/sources.list.d/anydesk.list > /dev/null

# 更新索引並安裝
sudo apt update
sudo apt install -y anydesk
