# 修復 Intel GPU 掛起導致系統凍結

## 問題描述

症狀：系統突然完全凍結，滑鼠鍵盤無回應，只能強制關機。

根因：**Intel Meteor Lake-P 整合顯示卡**（i915 驅動）的 GUC（GPU 微控制器）
TLB 失效機制出現逾時，導致 GPU 核心掛起（GPU HANG）。
由於 GNOME Shell 依賴 GPU 渲染畫面，GPU 掛起時整台機器就凍結。

kernel 日誌關鍵錯誤（`journalctl -b -1 -k | grep i915`）：

```
i915 0000:00:02.0: [drm] *ERROR* GT0: GUC: TLB invalidation response timed out
i915 0000:00:02.0: [drm] GPU HANG: ecode 12:0:00000000
i915 0000:00:02.0: [drm] GT0: Resetting chip for stopped heartbeat on rcs0
```

## 修復方式（依嘗試順序）

### 1. 切換到 NVIDIA-only 模式（部分有效，仍會 crash）

機器有 NVIDIA RTX 500 Ada Laptop GPU，先讓 GNOME Shell 改用 NVIDIA 渲染：

```bash
sudo prime-select nvidia
```

> **Wayland 限制**：即使切到 NVIDIA 模式，Intel GPU 仍負責 display scanout
> （把畫面輸出到螢幕），i915 GUC bug 還是會觸發。需配合下面的 kernel 參數。

### 2. ⚠️ `i915.enable_guc=2` 在 Meteor Lake 上會 boot 失敗

不要嘗試這個參數。在 Meteor Lake 上 GUC submission 是強制的，
設定 `i915.enable_guc=2` 會讓系統無法開機。

如果不慎加了這個參數導致進不去系統，開機時在 GRUB 畫面按 `e` 編輯開機項目，
把這段參數刪掉再按 `Ctrl+X` 開機，然後改 `/etc/default/grub` 永久移除。

### 3. ✅ 降低 i915 功耗管理複雜度（目前使用中）

編輯 `/etc/default/grub`：

```bash
sudo nano /etc/default/grub
```

修改 `GRUB_CMDLINE_LINUX_DEFAULT`，加入三個參數：

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash nvidia-drm.modeset=1 i915.enable_psr=0 i915.enable_fbc=0 i915.enable_dc=0"
```

| 參數 | 作用 |
|---|---|
| `i915.enable_psr=0` | 關閉 Panel Self Refresh |
| `i915.enable_fbc=0` | 關閉 framebuffer 壓縮 |
| `i915.enable_dc=0` | 關閉 display power gating |

更新 GRUB 後重開機：

```bash
sudo update-grub
sudo reboot
```

> **代價**：電池會稍微比較耗電（關掉省電功能）。
> **觀察期**：跑幾天 GPU 密集應用（DaVinci Resolve、瀏覽器影片）確認是否還會 crash。

### 4. 終極方案：切換到 X11（若上述仍 crash）

X11 模式下 NVIDIA 完全接管顯示輸出，Intel GPU 進入閒置狀態，肯定不會再 crash。
登入畫面點右下角齒輪選 **「Ubuntu on Xorg」**，或強制 GDM 用 X11：

```bash
sudo nano /etc/gdm3/custom.conf
# 取消註解：WaylandEnable=false
```

代價是失去 Wayland 的優點（手勢、分數縮放、安全隔離）。

## 驗證

確認 kernel 參數已套用：

```bash
cat /proc/cmdline
# 應看到 nvidia-drm.modeset=1 i915.enable_psr=0 i915.enable_fbc=0 i915.enable_dc=0
```

確認 prime 模式：

```bash
prime-select query
# 應顯示：nvidia
```

確認 NVIDIA 驅動正常：

```bash
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
```

確認 NVIDIA 渲染可用（Wayland 環境下需加環境變數）：

```bash
__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia glxinfo | grep "OpenGL renderer"
# 應顯示：OpenGL renderer string: NVIDIA RTX 500 Ada Generation Laptop GPU/PCIe/SSE2
```

> **注意（Wayland）**：直接跑 `glxinfo | grep "OpenGL renderer"` 可能仍顯示
> `Mesa Intel(R) Graphics (MTL)`——這是 XWayland 相容層的正常行為，
> 不代表修復沒生效。

## 還原（如需切回 Intel 或 on-demand 模式）

```bash
sudo prime-select on-demand   # 混合模式（省電）
sudo prime-select intel       # 純 Intel 模式
```

切換後需重開機才會生效。i915 kernel 參數可保留或從 `/etc/default/grub` 移除。

## 事後排查

凍結後下次開機，可執行以下指令查看上次的 GPU 錯誤：

```bash
# 上次開機的 Intel GPU 錯誤
journalctl -b -1 -k | grep -E "i915|GUC|GPU HANG"

# 計算 GPU HANG 發生次數
journalctl -b -1 -k | grep -c "GPU HANG"

# GPU 錯誤狀態快照（需在凍結後、重開機前才能讀到）
cat /sys/class/drm/card1/error
```
