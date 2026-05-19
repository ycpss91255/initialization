# 修復 OBS 觸發 GNOME Shell 崩潰回到登入畫面

## 問題描述

症狀：開啟 OBS Studio 錄影後沒多久，畫面凍結 → 黑畫面 → 自動跳回 GDM 登入畫面，
原本開的應用程式（包含 tmux、瀏覽器）全部被殺。**這跟 GPU 凍結不同**：

- GPU 凍結 → 鍵盤滑鼠完全無反應，只能強制關機（見 [[FIX-GPU-FREEZE]]）
- 這次是 mutter（GNOME Shell 的 compositor）被殺，GDM 強制重啟你的 session

排除證據：
- `journalctl -b 0 -k | grep -E "i915|GPU HANG|GUC"` 完全乾淨，沒有 GPU 錯誤
- 沒有 OOM kill，記憶體還很充裕
- 沒有 segfault / coredump

## 根因

`Ubuntu 24.04 + GNOME 46 (mutter 46.2) + OBS 32 + Wayland PipeWire screencast`
是公開的不穩定組合。具體觸發點：

1. **OBS 預設用 Intel iGPU 渲染自己的 OpenGL context**（即使在 prime-select nvidia 下），
   跟 mutter 搶 i915 驅動資源
2. OBS UI 跑 Qt Wayland，直接戳到 compositor
3. screencast 走 xdg-desktop-portal + PipeWire，在 mutter 上長時間運作會撐爆

關鍵 log 證據（OBS 啟動 30 秒內 user@1000.service 就被收掉）：

```
11:53:03 com.obsproject.Studio: Platform: Wayland
11:53:03 com.obsproject.Studio: Loading up OpenGL on adapter Intel Mesa Intel(R) Graphics (MTL)
11:53:33 systemd[1]: Stopping user@1000.service - User Manager for UID 1000...
11:53:34 wireplumber: stopped by signal: Terminated
```

## 修復方式

建立 user-level desktop entry 覆寫檔，強制 OBS Qt 走 XWayland
（`QT_QPA_PLATFORM=xcb`）→ UI 不直接撞 Wayland compositor，降低
觸發 mutter 崩潰的機率。

> **不要加 NVIDIA PRIME offload**（`__NV_PRIME_RENDER_OFFLOAD=1` 等）
> ——詳見下方〈為什麼不加 NVIDIA offload〉一節。

```bash
mkdir -p ~/.local/share/applications
```

建立 `~/.local/share/applications/com.obsproject.Studio.desktop`：

```ini
[Desktop Entry]
Version=1.0
Type=Application
Name=OBS Studio
GenericName=Streaming/Recording Software
Comment=Free and Open Source Streaming/Recording Software
Exec=env QT_QPA_PLATFORM=xcb obs
Icon=com.obsproject.Studio
Terminal=false
Categories=AudioVideo;Recorder;
StartupNotify=true
StartupWMClass=com.obsproject.Studio
MimeType=application/x-obs-scene-collection;
Keywords=streaming;recording;broadcasting;capture;screencast;
```

重整 desktop database（不一定必要，登出登入也會自動更新）：

```bash
update-desktop-database ~/.local/share/applications/
```

## 為什麼不加 NVIDIA offload

最初嘗試過 `__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia`，
目的是讓 OBS 的 OpenGL context 跑在 NVIDIA 上，避免跟 mutter 搶 i915 資源。
結果 **OBS 預覽全黑**——這是上游確認的 EGL/dmabuf bug：

- OBS 把 PipeWire 給的 buffer 當 `GL_TEXTURE_2D` import
- NVIDIA 的 EGL 實作只能把 linear buffer 當 `GL_TEXTURE_EXTERNAL_OES`
- Intel iGPU 產的 dmabuf 過給 NVIDIA context → import 失敗 → 黑畫面

上游 issue：
[obs-studio#6984](https://github.com/obsproject/obs-studio/issues/6984)、
[obs-studio#9741](https://github.com/obsproject/obs-studio/issues/9741)、
[NVIDIA open-gpu-kernel-modules#467](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/467)
都是同一個跨卡 dmabuf 問題，多年未解。

**目前 OBS 官方建議的 workaround 就是「OBS 跑在 iGPU 上」**，我們現在這樣。
代價是 OBS 仍會跟 mutter 共用 i915，崩 compositor 的風險還在（只是被
XWayland 那層減輕）。如果穩定性還是不夠，請走〈替代方案〉的方案 C。

## 驗證

1. 關掉現在跑的 OBS（如果有）
2. **從 Activities 選單**重新開 OBS（不要在終端機跑 `obs`，那會走系統設定）
3. OBS 開啟後 `Help → Log Files → View Current Log`，確認：
   - `Platform: XCB`（不是 `Platform: Wayland`）
   - `Loading up OpenGL on adapter NVIDIA Corporation NVIDIA RTX 500 Ada Generation Laptop GPU/PCIe/SSE2`
     （不是 `Intel ... (MTL)`）

如果 log 還是 Wayland / Intel → 登出再登入讓 GNOME 重掃 desktop file。

## 還原

```bash
rm ~/.local/share/applications/com.obsproject.Studio.desktop
```

## 替代方案

### 方案 A：GNOME 內建螢幕錄影（短螢幕首選）

如果只是要錄短螢幕（操作示範、bug 重現），**根本不用開 OBS**，
GNOME 內建螢幕錄影更輕量、完全不會撞 compositor：

- `Ctrl + Shift + Alt + R` 開始錄
- 螢幕上方紅點亮起，再按一次同組合鍵停止
- 檔案存到 `~/Videos/Screencasts/`

### 方案 B：強制 mutter 在 NVIDIA 上渲染（不推薦）

理論上 compositor 和 OBS 都跑 NVIDIA → dmabuf 同卡 → 可以開 NVIDIA offload。
但在 Optimus 筆電（包括這台 Meteor Lake + RTX 500 Ada）內顯線路是
**接到 iGPU**，i915 永遠脫不開 scanout 角色，[[FIX-GPU-FREEZE]] 的
PSR/FBC/DC 問題還是會在；且 mutter 沒提供乾淨的 primary GPU 設定 API，
要靠 udev rule 或 `MUTTER_DEBUG_PREFERRED_PRIMARY_GPU` 這種 hack。
複雜度高、效益低，**不推薦**。

### 方案 C：錄影時切到 X11 session（重度使用首選）

X11 下 OBS 走 `xshm` / `xcomposite` 直接抓畫面，
**完全不需要 PipeWire portal、沒有跨卡 dmabuf、沒有 mutter contention**。
這是 Linux 上最穩定的螢幕錄影組合。

切換方式：
1. 登出
2. GDM 登入畫面右下角齒輪選 **「Ubuntu on Xorg」**
3. 用完 OBS 再登出切回 Wayland

代價是失去 Wayland 的優點（手勢、分數縮放、安全隔離）。
如果你重度依賴 OBS，可以考慮直接永久切 X11（見 [[FIX-GPU-FREEZE]] 終極方案）。

OBS 一般使用留給「要多軌道、推流、複雜場景合成」這類重度需求即可。

## 事後排查

如果再次發生「畫面黑 → 回登入畫面」，先確認是 mutter 崩而不是 GPU 凍結：

```bash
# 1. 確認沒有 GPU 錯誤（如果有 → 走 FIX-GPU-FREEZE.md）
journalctl -b 0 -k | grep -E "i915|GPU HANG|GUC"

# 2. 找 session 被收掉的時刻
journalctl --since "today" | grep -E "Stopping user@1000.service"

# 3. 看 session 死前 30 秒在做什麼
journalctl --since "2026-MM-DD HH:MM:00" --until "2026-MM-DD HH:MM:30" \
  | grep -vE "Can't update stage views|pipewire\[.*\]"
```

如果 OBS 的 log 同時出現在那個時間區段，且 kernel log 乾淨 → 就是這個問題。

## 參考資料

- [Obs Studio Fix Pipewire With Nvidia and Intel Graphics on Niri and Wayland (Andrew McCall, 2026/01)](https://andrew-mccall.com/blog/2026/01/obs-studio-fix-pipewire-with-nvidia-and-intel-graphics-on-niri-and-wayland/)
  — Niri 上的解法，給 GNOME mutter 用要自己 hack（見方案 B 評估）
- [nvidia prime offloading breaks preview on EGL backend · obs-studio#6984](https://github.com/obsproject/obs-studio/issues/6984)
- [black screen capture on wayland · obs-studio#9741](https://github.com/obsproject/obs-studio/issues/9741)
  — 跨卡 dmabuf 黑畫面的技術根因
- [Pipewire screen sharing under Wayland results in black canvas · NVIDIA/open-gpu-kernel-modules#467](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/467)
- [[SOLVED] Cannot capture screen in OBS Studio (wayland + nvidia) · Arch Linux Forums](https://bbs.archlinux.org/viewtopic.php?id=293108)
  — X11 session 作為標準解法
- [Desktop capture on Wayland / Nvidia results in black/grey screen · obs-studio#6208](https://github.com/obsproject/obs-studio/issues/6208)
