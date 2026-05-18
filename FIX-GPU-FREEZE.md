# 修復 Intel GPU 掛起導致系統凍結

## 問題描述

症狀：系統突然完全凍結，滑鼠鍵盤無回應，只能強制關機。

根因：GNOME Shell 預設使用 **Intel Meteor Lake-P 整合顯示卡**（i915 驅動）渲染畫面。
Intel GUC（GPU 微控制器）的 TLB 失效機制出現逾時，導致 GPU 核心掛起（GPU HANG），
GNOME Shell 無法繼續繪製畫面，整台機器就此凍結。

kernel 日誌關鍵錯誤（`journalctl -b -1 -k | grep i915`）：

```
i915 0000:00:02.0: [drm] *ERROR* GT0: GUC: TLB invalidation response timed out
i915 0000:00:02.0: [drm] GPU HANG: ecode 12:0:00000000
i915 0000:00:02.0: [drm] GT0: Resetting chip for stopped heartbeat on rcs0
```

## 解法：切換到 NVIDIA-only 模式

機器同時有 Intel 整合顯示卡與 NVIDIA RTX 500 Ada Laptop GPU，
切換讓 GNOME Shell 改用 NVIDIA 顯示卡渲染，繞開有問題的 Intel i915 驅動。

```bash
sudo prime-select nvidia
```

重開機後生效。

## 驗證

重開後確認目前使用哪張卡：

```bash
prime-select query
# 應顯示：nvidia
```

確認 NVIDIA 驅動正常運作：

```bash
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
# 應顯示顯示卡名稱與驅動版本
```

確認 NVIDIA 渲染可用（Wayland 環境下需加環境變數）：

```bash
__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia glxinfo | grep "OpenGL renderer"
# 應顯示：OpenGL renderer string: NVIDIA RTX 500 Ada Generation Laptop GPU/PCIe/SSE2
```

> **注意（Wayland）**：直接跑 `glxinfo | grep "OpenGL renderer"` 可能仍顯示
> `Mesa Intel(R) Graphics (MTL)`，這是正常現象——`glxinfo` 走的是 XWayland
> 相容層，該路徑在 Wayland 下預設還是用 Intel 橋接。
> GNOME Shell 的 Wayland compositor 本身已在用 NVIDIA 渲染，Intel GPU 不再是主力，
> 不影響修復效果。

## 還原（如需切回 Intel 或 on-demand 模式）

```bash
# 切回混合模式（省電，Intel 渲染桌面，NVIDIA 跑高效能應用）
sudo prime-select on-demand

# 切回純 Intel 模式
sudo prime-select intel
```

> 注意：切換後都需要重開機才會生效。

## 事後排查（若未切換仍想觀察）

凍結後下次開機，可執行以下指令查看上次的 GPU 錯誤：

```bash
# 上次開機的 Intel GPU 錯誤
journalctl -b -1 -k | grep -E "i915|GUC|GPU HANG"

# GPU 錯誤狀態快照（需在凍結後、重開機前才能讀到）
cat /sys/class/drm/card1/error
```
