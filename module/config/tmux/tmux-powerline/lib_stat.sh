# shellcheck shell=bash
# Non-blocking mem% + cpu% + per-discrete-GPU sampler, shared by the
# mem_pct / cpu_pct / gpu_pct* segments and the theme (which colors each
# pill AND its left separator from the same cached usage %, so the round
# separators blend with the dynamic gradients).
#
# Why not tmux-mem-cpu-load: that binary's CPU reading blocks for its whole
# -i N interval (it sleeps N seconds to sample). Here CPU% is the delta of
# /proc/stat between consecutive refreshes -- no sleep, no blocking.
#
# Everything is cached with a sub-refresh TTL so every reader in one cycle
# (theme + mem_pct + cpu_pct + each gpu_pct, and the separate left/right
# powerline.sh invocations) shares a SINGLE computation and stays consistent,
# and the /proc/stat snapshot advances exactly once per cycle.
#
# GPU policy: only DISCRETE GPUs are shown (integrated ones -- PCI bus 00 --
# are skipped), one pill each, ordered by PCI address. Vendor is derived from
# the PCI vendor id (0x10de NVIDIA / 0x1002 AMD / 0x8086 Intel). NVIDIA usage
# comes from nvidia-smi (matched by PCI bus id); AMD/Intel-discrete usage from
# the card's sysfs gpu_busy_percent.

_STAT_DIR="${TMUX_TMPDIR:-${TMPDIR:-/tmp}}"
_STAT_CACHE="${_STAT_DIR}/tmux-pl-stat-$(id -u)"
_STAT_SNAP="${_STAT_DIR}/tmux-pl-stat-snap-$(id -u)"
_STAT_LOCK="${_STAT_DIR}/tmux-pl-stat-lock-$(id -u)"
# System-info sample interval (the ONLY knob for how often mem/cpu/gpu are
# actually read). A computed sample is reused for this long; every reader in
# the window (theme + all segments + every pane's left/right/window
# invocations) shares that one sample, so /proc and nvidia-smi are touched
# at most once per this interval globally -- no matter how many panes or how
# often the bar redraws. Set it a touch BELOW the tmux status-interval so a
# fresh sample lands on each redraw, but well ABOVE the few-ms spread between
# one redraw's left/right/window invocations so they share. With
# status-interval 5s, 4.5s gives one real sample per ~5s.
_STAT_TTL_NS=4500000000   # 4.5s  (a touch below the 5s tmux status-interval)

# used = MemTotal - MemAvailable (the kernel's own "available" estimate).
_stat_read_mem() {
	local k v total="" avail=""
	while read -r k v _; do
		case "$k" in
			MemTotal:) total=$v ;;
			MemAvailable:) avail=$v ;;
		esac
		[ -n "$total" ] && [ -n "$avail" ] && break
	done < /proc/meminfo
	if [ -n "$total" ] && [ -n "$avail" ] && [ "$total" -gt 0 ]; then
		awk -v t="$total" -v a="$avail" 'BEGIN { printf "%.1f", (t - a) * 100 / t }'
	else
		echo 0
	fi
}

# cpu% from the delta of the aggregate /proc/stat "cpu" line vs the last
# snapshot. idle_all = idle + iowait; busy = total - idle_all.
_stat_read_cpu() {
	local _cpu user nice system idle iowait irq softirq steal _rest
	read -r _cpu user nice system idle iowait irq softirq steal _rest < /proc/stat
	local total=$((user + nice + system + idle + iowait + irq + softirq + steal))
	local idle_all=$((idle + iowait))

	local prev_total=0 prev_idle=0
	[ -r "$_STAT_SNAP" ] && read -r prev_total prev_idle < "$_STAT_SNAP"
	printf '%s %s\n' "$total" "$idle_all" > "${_STAT_SNAP}.${BASHPID}" \
		&& mv "${_STAT_SNAP}.${BASHPID}" "$_STAT_SNAP"

	local dt=$((total - prev_total)) di=$((idle_all - prev_idle))
	# No usable previous snapshot, or clock/counter went backwards: report 0
	# for this frame rather than a bogus spike.
	if [ "$prev_total" -eq 0 ] || [ "$dt" -le 0 ] || [ "$di" -lt 0 ]; then
		echo 0
	else
		awk -v dt="$dt" -v di="$di" 'BEGIN { printf "%.1f", (dt - di) * 100 / dt }'
	fi
}

# Emit one "<vendor>:<usage>" token per DISCRETE GPU, ordered by PCI address,
# space separated. Integrated GPUs (PCI bus 00) and non-GPU DRM nodes (the
# cardN-<connector> symlinks) are skipped. Prints nothing when there is no
# discrete GPU.
#
# Power-safety: nvidia-smi is fetched LAZILY and only when an AWAKE NVIDIA
# card is seen. On an Optimus laptop in prime-select on-demand mode the dGPU
# runtime-suspends (PCI D3) when idle; polling nvidia-smi every refresh would
# wake it each second and defeat the power gating (battery drain + heat --
# the fleet's Meteor Lake + RTX laptop cares, see its FIX-GPU-FREEZE notes).
# A suspended dGPU is idle by definition, so we report it as 0% WITHOUT
# waking it. (When prime-select is nvidia, the card stays active and this is
# a no-op.)
# Token per discrete GPU: "<vendor>:<usage>:<temp>:<vram_used>:<vram_total>"
# (temp in C, VRAM in MiB; any unknown field is 0). NVIDIA values come from one
# nvidia-smi call (usage, temp, memory.used, memory.total); AMD/Intel-discrete
# from sysfs (gpu_busy_percent, the card hwmon temp, mem_info_vram_*).
_stat_read_gpus() {
	local nvidia_map="" nvidia_tried=""
	local card base vid pciaddr bus vendor short rstatus rows="" line h
	local usage temp vused vtotal
	for card in /sys/class/drm/card[0-9]*; do
		base=${card##*/}
		# Only real cards (cardN), not connectors (cardN-DP-1 etc).
		[[ "$base" =~ ^card[0-9]+$ ]] || continue
		[ -r "$card/device/vendor" ] || continue

		vid=$(cat "$card/device/vendor" 2>/dev/null)
		pciaddr=$(basename "$(readlink -f "$card/device" 2>/dev/null)")   # 0000:01:00.0
		bus=${pciaddr#*:}; bus=${bus%%:*}                                  # 01
		# Integrated GPUs live on PCI bus 00: skip them.
		[ "$bus" = "00" ] && continue

		case "$vid" in
			0x10de) vendor=NVIDIA ;;
			0x1002) vendor=AMD ;;
			0x8086) vendor=Intel ;;
			*)      vendor=GPU ;;
		esac

		usage=""; temp=""; vused=""; vtotal=""
		if [ "$vendor" = NVIDIA ]; then
			rstatus=$(cat "/sys/bus/pci/devices/${pciaddr}/power/runtime_status" 2>/dev/null)
			if [ "$rstatus" = "suspended" ]; then
				# Asleep: report idle without waking it via nvidia-smi.
				usage=0; temp=0; vused=0; vtotal=0
			else
				if [ -z "$nvidia_tried" ]; then
					nvidia_tried=1
					command -v nvidia-smi >/dev/null 2>&1 && nvidia_map=$(nvidia-smi \
						--query-gpu=pci.bus_id,utilization.gpu,temperature.gpu,memory.used,memory.total \
						--format=csv,noheader,nounits 2>/dev/null)
				fi
				short=${pciaddr#0000:}   # 01:00.0
				line=$(awk -F', ' -v p="$short" 'index($1, p) { print; exit }' <<<"$nvidia_map")
				if [ -n "$line" ]; then
					usage=$(awk -F', ' '{ print $2 }' <<<"$line")
					temp=$(awk -F', ' '{ print $3 }' <<<"$line")
					vused=$(awk -F', ' '{ print $4 }' <<<"$line")
					vtotal=$(awk -F', ' '{ print $5 }' <<<"$line")
				fi
			fi
		fi
		# AMD/Intel discrete (or NVIDIA fallback): sysfs.
		[ -z "$usage" ] && [ -r "$card/device/gpu_busy_percent" ] \
			&& usage=$(cat "$card/device/gpu_busy_percent" 2>/dev/null)
		[ -z "$vused" ] && [ -r "$card/device/mem_info_vram_used" ] \
			&& vused=$(( $(cat "$card/device/mem_info_vram_used" 2>/dev/null || echo 0) / 1048576 ))
		[ -z "$vtotal" ] && [ -r "$card/device/mem_info_vram_total" ] \
			&& vtotal=$(( $(cat "$card/device/mem_info_vram_total" 2>/dev/null || echo 0) / 1048576 ))
		if [ -z "$temp" ]; then
			for h in "$card/device/hwmon"/hwmon*/temp1_input; do
				[ -r "$h" ] && { temp=$(( $(cat "$h" 2>/dev/null || echo 0) / 1000 )); break; }
			done
		fi

		case "$usage" in '' | *[!0-9]*) usage=0 ;; esac
		case "$temp" in '' | *[!0-9]*) temp=0 ;; esac
		case "$vused" in '' | *[!0-9]*) vused=0 ;; esac
		case "$vtotal" in '' | *[!0-9]*) vtotal=0 ;; esac

		rows+="${pciaddr} ${vendor}:${usage}:${temp}:${vused}:${vtotal}"$'\n'
	done

	# Stable order by PCI address, then drop the sort key.
	[ -n "$rows" ] || return 0
	printf '%s' "$rows" | sort | awk '{ print $2 }' | tr '\n' ' ' | sed 's/ *$//'
}

# CPU package temperature in whole degrees C (empty if unavailable). Instant
# sysfs read: prefer the x86_pkg_temp thermal zone, else a coretemp/k10temp/
# zenpower/cpu_thermal hwmon's temp1_input.
_stat_read_cputemp() {
	local zone t="" hw
	for zone in /sys/class/thermal/thermal_zone*; do
		[ "$(cat "$zone/type" 2>/dev/null)" = "x86_pkg_temp" ] || continue
		t=$(cat "$zone/temp" 2>/dev/null); break
	done
	if [ -z "$t" ]; then
		for hw in /sys/class/hwmon/hwmon*; do
			case "$(cat "$hw/name" 2>/dev/null)" in
				coretemp | k10temp | zenpower | cpu_thermal) ;;
				*) continue ;;
			esac
			t=$(cat "$hw/temp1_input" 2>/dev/null)
			[ -n "$t" ] && break
		done
	fi
	case "$t" in '' | *[!0-9]*) return 0 ;; esac
	echo $((t / 1000))
}

# Percent used of the root filesystem (integer, empty on failure).
_stat_read_disk() {
	df -P / 2>/dev/null | awk 'NR == 2 { gsub("%", "", $5); print $5 }'
}

# Parse the cache file into STAT_MEM_PCT / STAT_CPU_PCT / STAT_CPU_TEMP /
# STAT_DISK_PCT and the GPU arrays (+ STAT_GPU_N). Returns 0 only when the
# sample is fresh (age within TTL) for "now" (ns); cached_ts is validated
# numeric and a negative age (clock stepped back) counts as stale.
# Cache line: <mem> <cpu> <cputemp> <disk> <ts> <ngpu> <gtok0> <gtok1> ...
# gtok = <vendor>:<usage>:<temp>:<vram_used>:<vram_total>; cputemp/disk use "-"
# when unavailable (parsed back to empty).
_stat_parse_cache() {
	local now="$1" i age cached_ts _v _u _t _vu _vt
	local -a f=()
	[ -r "$_STAT_CACHE" ] || return 1
	read -r -a f < "$_STAT_CACHE"
	[ "${#f[@]}" -ge 6 ] || return 1
	STAT_MEM_PCT=${f[0]}
	STAT_CPU_PCT=${f[1]}
	STAT_CPU_TEMP=${f[2]}; [ "$STAT_CPU_TEMP" = "-" ] && STAT_CPU_TEMP=""
	STAT_DISK_PCT=${f[3]};  [ "$STAT_DISK_PCT" = "-" ] && STAT_DISK_PCT=""
	cached_ts=${f[4]}
	STAT_GPU_N=${f[5]}
	STAT_GPU_VENDOR=(); STAT_GPU_USAGE=(); STAT_GPU_TEMP=(); STAT_GPU_VUSED=(); STAT_GPU_VTOTAL=()
	case "$STAT_GPU_N" in ''|*[!0-9]*) STAT_GPU_N=0 ;; esac
	for ((i = 0; i < STAT_GPU_N; i++)); do
		IFS=: read -r _v _u _t _vu _vt <<<"${f[6 + i]}"
		STAT_GPU_VENDOR[i]=$_v; STAT_GPU_USAGE[i]=$_u; STAT_GPU_TEMP[i]=$_t
		STAT_GPU_VUSED[i]=$_vu; STAT_GPU_VTOTAL[i]=$_vt
	done
	case "$cached_ts" in '' | *[!0-9]*) return 1 ;; esac
	age=$((now - cached_ts))
	[ "$age" -ge 0 ] && [ "$age" -lt "$_STAT_TTL_NS" ]
}

_stat_recompute() {
	local now="$1" gpus i cputemp disk _v _u _t _vu _vt
	local -a toks=()
	STAT_MEM_PCT=$(_stat_read_mem)
	STAT_CPU_PCT=$(_stat_read_cpu)
	STAT_CPU_TEMP=$(_stat_read_cputemp)
	STAT_DISK_PCT=$(_stat_read_disk)
	gpus=$(_stat_read_gpus)   # "v0:u0:t0:vu0:vt0 ..." or empty

	# Rebuild the GPU arrays from the freshly sampled tokens.
	STAT_GPU_VENDOR=(); STAT_GPU_USAGE=(); STAT_GPU_TEMP=(); STAT_GPU_VUSED=(); STAT_GPU_VTOTAL=()
	[ -n "$gpus" ] && read -r -a toks <<<"$gpus"
	STAT_GPU_N=${#toks[@]}
	for ((i = 0; i < STAT_GPU_N; i++)); do
		IFS=: read -r _v _u _t _vu _vt <<<"${toks[i]}"
		STAT_GPU_VENDOR[i]=$_v; STAT_GPU_USAGE[i]=$_u; STAT_GPU_TEMP[i]=$_t
		STAT_GPU_VUSED[i]=$_vu; STAT_GPU_VTOTAL[i]=$_vt
	done

	cputemp=${STAT_CPU_TEMP:--}
	disk=${STAT_DISK_PCT:--}
	printf '%s %s %s %s %s %s%s\n' "$STAT_MEM_PCT" "$STAT_CPU_PCT" "$cputemp" "$disk" \
		"$now" "$STAT_GPU_N" "${gpus:+ $gpus}" \
		> "${_STAT_CACHE}.${BASHPID}" && mv "${_STAT_CACHE}.${BASHPID}" "$_STAT_CACHE"
}

# Populate STAT_MEM_PCT, STAT_CPU_PCT and the GPU arrays. Reuses a fresh
# cached sample; otherwise recomputes under an flock so that, when the
# separate left/right powerline.sh processes both miss the cache in the same
# cycle, only ONE advances the /proc/stat snapshot (the other reuses the
# freshly written cache) -- keeping the CPU delta over a full interval and
# both sides consistent.
stat_sample() {
	local now lockfd=""
	now=$(date +%s%N)
	_stat_parse_cache "$now" && return 0

	if exec {lockfd}>"$_STAT_LOCK" 2>/dev/null && flock -w 0.15 "$lockfd"; then
		# Someone may have refreshed the cache while we waited for the lock.
		if ! _stat_parse_cache "$(date +%s%N)"; then
			_stat_recompute "$now"
		fi
		exec {lockfd}>&-
	else
		# Couldn't lock (timeout / no flock): reuse the cache if present,
		# else do an unlocked compute (cold start / degraded path). The
		# second parse forces acceptance of an existing (stale) cache.
		[ -n "$lockfd" ] && exec {lockfd}>&-
		if [ -r "$_STAT_CACHE" ]; then
			_stat_parse_cache "$now" || _stat_parse_cache "$((now + _STAT_TTL_NS))"
		else
			_stat_recompute "$now"
		fi
	fi
}

# Accessors for the Nth discrete GPU (0-based). Empty when out of range, so
# a gpu_pct pill whose index exceeds the GPU count renders nothing. (These
# also keep the STAT_GPU_* arrays "read" within this file for linters; the
# real consumers are the gpu_pct segments and the theme.)
stat_gpu_vendor() { echo "${STAT_GPU_VENDOR[$1]:-}"; }
stat_gpu_usage()  { echo "${STAT_GPU_USAGE[$1]:-}"; }
stat_gpu_temp()   { echo "${STAT_GPU_TEMP[$1]:-}"; }
stat_gpu_vused()  { echo "${STAT_GPU_VUSED[$1]:-}"; }
stat_gpu_vtotal() { echo "${STAT_GPU_VTOTAL[$1]:-}"; }

# Echo "<level> <ac>" for the battery: level is the integer percent charge
# (empty when there is no battery), ac is 1 when any Mains supply is online
# else 0. A battery's charge is an instant sysfs read (no sampling window
# needed), so this is not part of the cached /proc-delta sampler. Devices are
# found by type (Battery / Mains), same as the battery segment.
stat_battery() {
	local ac=0 dev full now total_full=0 total_now=0 level=""
	while read -r dev; do
		[ -n "$dev" ] || continue
		[ "$(cat "$dev/online" 2>/dev/null)" = "1" ] && ac=1
	done <<<"$(grep -l "Mains" /sys/class/power_supply/*/type 2>/dev/null | sed -e 's,/type$,,')"
	while read -r dev; do
		[ -n "$dev" ] || continue
		full="$dev/charge_full"; now="$dev/charge_now"
		if [ ! -r "$full" ] || [ ! -r "$now" ]; then full="$dev/energy_full"; now="$dev/energy_now"; fi
		if [ -r "$full" ] && [ -r "$now" ]; then
			total_full=$((total_full + $(cat "$full")))
			total_now=$((total_now + $(cat "$now")))
		fi
	done <<<"$(grep -l "Battery" /sys/class/power_supply/*/type 2>/dev/null | sed -e 's,/type$,,')"
	if [ "$total_full" -gt 0 ]; then
		[ "$total_now" -gt "$total_full" ] && total_now=$total_full
		level=$((100 * total_now / total_full))
	fi
	echo "${level} ${ac}"
}

_STAT_NET_CACHE="${_STAT_DIR}/tmux-pl-net-$(id -u)"
_STAT_NET_SNAP="${_STAT_DIR}/tmux-pl-netsnap-$(id -u)"

# Emit one "<type>:<ipv4>:<rxrate>:<txrate>" token per active, non-virtual
# network interface, ordered by default-route priority, space separated. Type
# is wifi / eth / vpn; rates are bytes/sec since the previous snapshot (0 if no
# prior sample). Loopback and container/bridge/virtual interfaces (lo, docker*,
# br-*, veth*, virbr*, vmnet*, tap*) are skipped.
_stat_read_nets() {
	# Priority = default-route metric (lower metric reaches the router with
	# higher priority -> sorted leftmost). Interfaces WITHOUT a default route
	# (e.g. a split-tunnel VPN, a link-local NIC) get a large sentinel so they
	# sort after the internet-facing ones.
	local now iface ip typ path rows="" snap="" dev val
	local rx tx prx ptx pts dt rxrate txrate devtype arptype
	local -A _metric=() _prev=()
	now=$(date +%s%N)
	# Previous rx/tx snapshot: "iface" -> "rx:tx:ts".
	if [ -r "$_STAT_NET_SNAP" ]; then
		while read -r dev val; do [ -n "$dev" ] && _prev[$dev]=$val; done < "$_STAT_NET_SNAP"
	fi
	while read -r dev val; do
		[ -n "$dev" ] || continue
		_metric[$dev]=$val
	done < <(ip -4 route show default 2>/dev/null | awk '
		{ dev=""; m=0; for (i = 1; i <= NF; i++) { if ($i == "dev") dev = $(i+1); if ($i == "metric") m = $(i+1) }
		  if (dev != "") print dev, m }')

	while read -r iface ip; do
		[ -n "$iface" ] || continue
		case "$iface" in lo | docker* | br-* | veth* | virbr* | vmnet* | tap*) continue ;; esac
		ip=${ip%%/*}
		[ -n "$ip" ] || continue
		path="/sys/class/net/${iface}"
		# Classify by robust device attributes, not just name: a VPN can be a
		# WireGuard/tun link with an arbitrary name (e.g. "guotai"). uevent
		# DEVTYPE tags wlan/wireguard; the ARP hardware type (type file) is
		# 65534 (ARPHRD_NONE, tun/wireguard) or 512 (ARPHRD_PPP) for tunnels,
		# and 1 (ARPHRD_ETHER) for real wired/wifi NICs.
		devtype=$(sed -n 's/^DEVTYPE=//p' "$path/uevent" 2>/dev/null)
		arptype=$(cat "$path/type" 2>/dev/null)
		if [ -d "$path/wireless" ] || [ -e "$path/phy80211" ] || [ "$devtype" = wlan ]; then
			typ=wifi
		elif [ "$devtype" = wireguard ] || [ "$arptype" = 65534 ] || [ "$arptype" = 512 ] \
			|| [ -e "$path/tun_flags" ] \
			|| [[ "$iface" == tun* || "$iface" == tap* || "$iface" == wg* || "$iface" == ppp* ]]; then
			typ=vpn
		else
			typ=eth
		fi
		# Throughput: bytes/sec since the previous snapshot for this iface.
		rx=$(cat "$path/statistics/rx_bytes" 2>/dev/null)
		tx=$(cat "$path/statistics/tx_bytes" 2>/dev/null)
		rxrate=0; txrate=0
		IFS=: read -r prx ptx pts <<<"${_prev[$iface]:-}"
		if [ -n "$pts" ] && [ "$now" -gt "$pts" ]; then
			dt=$((now - pts))
			[ -n "$rx" ] && [ -n "$prx" ] && [ "$rx" -ge "$prx" ] && rxrate=$(((rx - prx) * 1000000000 / dt))
			[ -n "$tx" ] && [ -n "$ptx" ] && [ "$tx" -ge "$ptx" ] && txrate=$(((tx - ptx) * 1000000000 / dt))
		fi
		rows+="${_metric[$iface]:-99999} ${iface} ${typ}:${ip}:${rxrate}:${txrate}"$'\n'
		snap+="${iface} ${rx:-0}:${tx:-0}:${now}"$'\n'
	done < <(ip -4 -o addr show 2>/dev/null | awk '{print $2, $4}')

	# Persist the fresh totals for the next delta.
	printf '%s' "$snap" > "${_STAT_NET_SNAP}.${BASHPID}" \
		&& mv "${_STAT_NET_SNAP}.${BASHPID}" "$_STAT_NET_SNAP"

	[ -n "$rows" ] || return 0
	# Sort by metric (numeric, priority) then interface name, drop the keys.
	printf '%s' "$rows" | sort -k1,1n -k2,2 | awk '{ print $3 }' | tr '\n' ' ' | sed 's/ *$//'
}

# Populate STAT_NET_TYPE[] / STAT_NET_IP[] (+ STAT_NET_N) for the active
# interfaces. Cached with the sample TTL (interfaces change slowly) so the
# theme and every net_if pill share one enumeration instead of each running
# its own "ip" call.
_STAT_NET_LOCK="${_STAT_DIR}/tmux-pl-net-lock-$(id -u)"

_stat_net_parse_tok() {   # index token("type:ip:rx:tx")
	local _t _ip _rx _tx
	IFS=: read -r _t _ip _rx _tx <<<"$2"
	STAT_NET_TYPE[$1]=$_t; STAT_NET_IP[$1]=$_ip
	STAT_NET_RX[$1]=${_rx:-0}; STAT_NET_TX[$1]=${_tx:-0}
}
# Populate the STAT_NET_* arrays from the cache iff it is fresh; return 1 (stale
# / missing) otherwise.
_stat_net_try_cache() {
	local now="$1" i cached_ts
	local -a f=()
	[ -r "$_STAT_NET_CACHE" ] || return 1
	read -r -a f < "$_STAT_NET_CACHE"   # f[0]=ts, f[1..]=type:ip:rx:tx tokens
	cached_ts=${f[0]}
	case "$cached_ts" in '' | *[!0-9]*) return 1 ;; esac
	[ "$((now - cached_ts))" -ge 0 ] && [ "$((now - cached_ts))" -lt "$_STAT_TTL_NS" ] || return 1
	STAT_NET_TYPE=(); STAT_NET_IP=(); STAT_NET_RX=(); STAT_NET_TX=()
	STAT_NET_N=$(( ${#f[@]} - 1 ))
	for ((i = 0; i < STAT_NET_N; i++)); do _stat_net_parse_tok "$i" "${f[1 + i]}"; done
	return 0
}
_stat_net_recompute() {
	local now="$1" i toks
	local -a t=()
	toks=$(_stat_read_nets)
	[ -n "$toks" ] && read -r -a t <<<"$toks"
	STAT_NET_TYPE=(); STAT_NET_IP=(); STAT_NET_RX=(); STAT_NET_TX=()
	STAT_NET_N=${#t[@]}
	for ((i = 0; i < STAT_NET_N; i++)); do _stat_net_parse_tok "$i" "${t[i]}"; done
	printf '%s%s\n' "$now" "${toks:+ $toks}" \
		> "${_STAT_NET_CACHE}.${BASHPID}" && mv "${_STAT_NET_CACHE}.${BASHPID}" "$_STAT_NET_CACHE"
}
# Like stat_sample, serialise recompute under an flock so that when the left and
# right powerline.sh both miss the cache in one cycle only ONE advances the
# rx/tx snapshot (the other reuses the freshly written cache) -- otherwise the
# racing snapshot writes produce bogus throughput spikes.
stat_nets() {
	local now lockfd=""
	now=$(date +%s%N)
	_stat_net_try_cache "$now" && return 0
	if exec {lockfd}>"$_STAT_NET_LOCK" 2>/dev/null && flock -w 0.2 "$lockfd"; then
		_stat_net_try_cache "$(date +%s%N)" || _stat_net_recompute "$now"
		exec {lockfd}>&-
	else
		_stat_net_try_cache "$now" || _stat_net_recompute "$now"
	fi
}
stat_net_type() { echo "${STAT_NET_TYPE[$1]:-}"; }
stat_net_ip()   { echo "${STAT_NET_IP[$1]:-}"; }
stat_net_rx()   { echo "${STAT_NET_RX[$1]:-0}"; }
stat_net_tx()   { echo "${STAT_NET_TX[$1]:-0}"; }

# Shared 1-based index badge (md-numeric_N_box_outline, N = 1..9) used by the
# gpu_pct and net_if pills to number multiple same-kind instances. Codepoints
# are not arithmetic, so listed explicitly. Echoes empty for out-of-range n.
_STAT_NUM_ICON=(
	"󰎦"
	"󰎩"
	"󰎬"
	"󰎮"
	"󰎰"
	"󰎵"
	"󰎸"
	"󰎻"
	"󰎾"
)
stat_num_badge() { echo "${_STAT_NUM_ICON[$(( $1 - 1 ))]:-}"; }

# Linear-interpolate thm_blue (low load) -> thm_red (high load) by percentage,
# echoing a #rrggbb hex string. Endpoints default to Catppuccin Frappe if the
# theme palette vars are not in scope.
stat_gradient() {
	awk -v p="$1" -v blue="${thm_blue:-#8caaee}" -v red="${thm_red:-#e78284}" '
	BEGIN {
		if (p < 0) p = 0; if (p > 100) p = 100
		r1 = strtonum("0x" substr(blue, 2, 2)); g1 = strtonum("0x" substr(blue, 4, 2)); b1 = strtonum("0x" substr(blue, 6, 2))
		r2 = strtonum("0x" substr(red, 2, 2));  g2 = strtonum("0x" substr(red, 4, 2));  b2 = strtonum("0x" substr(red, 6, 2))
		printf "#%02x%02x%02x", \
			int(r1 + (r2 - r1) * p / 100 + 0.5), \
			int(g1 + (g2 - g1) * p / 100 + 0.5), \
			int(b1 + (b2 - b1) * p / 100 + 0.5)
	}'
}
