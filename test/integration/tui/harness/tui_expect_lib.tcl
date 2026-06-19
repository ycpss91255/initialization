# tui_expect_lib.tcl — reusable expect procs for the AC-10 layer-2 smoke
# harness (issue #73). Sourced by the *.exp flow scripts in this directory;
# future TUI screens (#71 Quick Setup, #72 Manage Installed) add new flow
# scripts on top of these procs.
#
# Contract (env vars, set by the bats wrapper tui_smoke_spec.bats):
#   TUI_ENTRY     absolute path to setup_ubuntu_tui.sh
#   TUI_FARM      sealed PATH dir (symlink farm + mock setup_ubuntu + the
#                 ONE backend under test — see helper/tui_harness.bash)
#   TUI_HOME      scratch HOME (must stay empty — zero-write assertion)
#   TUI_CLI_MOCK  mock setup_ubuntu path (TUI_CLI override, G4 data path)
#
# Procs:
#   tui_spawn            spawn the TUI on a fresh 80x24 pseudo-tty
#   tui_expect_text <s>  wait for literal screen text or die (exit 99)
#   tui_key_down / tui_key_enter / tui_key_space / tui_key_tab
#   tui_press_exit <b>   press the relabeled < Exit > button (per-backend Tabs)
#   tui_wait_exit_rc     wait for EOF, return the TUI process exit status
#   tui_die <msg>        diagnostic failure (exit 99, distinct from TUI rcs)

set timeout 20

proc tui_die {msg} {
    puts stderr "\nTUI-HARNESS FAIL: $msg"
    exit 99
}

proc tui_spawn {args} {
    # `spawn` inside a proc writes a proc-LOCAL spawn_id unless it is
    # declared global — without this, every later `expect` silently reads
    # stdin instead of the pty (EOF/timeout with an empty buffer).
    global env spawn_out spawn_id
    foreach v {TUI_ENTRY TUI_FARM TUI_HOME TUI_CLI_MOCK} {
        if {![info exists env($v)]} { tui_die "$v not set" }
    }
    # Optional extra argv (e.g. `--backend gum`) is appended to the TUI call
    # so a gum smoke can force the backend deterministically (#171), skipping
    # detection / the install prompt.
    # LINES/COLUMNS pin the ncurses/slang screen size deterministically
    # (CI has no real tty); TERM=xterm matches the terminfo baked into the
    # test-tools image (dockerfile comment: ncurses-terminfo).
    eval spawn env PATH=$env(TUI_FARM) HOME=$env(TUI_HOME) TERM=xterm \
        LINES=24 COLUMNS=80 TUI_CLI=$env(TUI_CLI_MOCK) \
        bash $env(TUI_ENTRY) $args
    # Also size the pty itself — ncurses prefers the winsize ioctl when
    # it is non-zero. Non-fatal: LINES/COLUMNS above still pin the size.
    catch {stty rows 24 columns 80 < $spawn_out(slave,name)}
}

proc tui_expect_text {txt} {
    expect {
        -exact $txt {}
        timeout { tui_die "timeout waiting for screen text: $txt" }
        eof {
            set st [wait]
            tui_die "unexpected EOF waiting for: $txt (wait: $st)\nbuffer: $expect_out(buffer)"
        }
    }
}

proc tui_expect_re {re what} {
    expect {
        -re $re {}
        timeout { tui_die "timeout waiting for $what (re: $re)" }
        eof {
            set st [wait]
            tui_die "unexpected EOF waiting for $what (wait: $st)"
        }
    }
}

# \x1bOB = SS3 cursor-down: what xterm's terminfo (kcud1) advertises in
# keypad-application mode, which dialog/ncurses enables; newt/slang
# accepts it too — one spelling drives both backends.
proc tui_key_down  {} { send -- "\x1bOB" }
proc tui_key_enter {} { send -- "\r" }
proc tui_key_space {} { send -- " " }
proc tui_key_tab   {} { send -- "\t" }

# Press the relabeled < Exit > (Cancel) button from the focused list.
# Button traversal differs per backend (probed empirically): dialog's Tab
# jumps from the list straight to the Cancel button, whiptail's Tab walks
# listbox → OK → Cancel.
proc tui_press_exit {backend} {
    tui_key_tab
    if {$backend eq "whiptail"} { tui_key_tab }
    tui_key_enter
}

proc tui_wait_exit_rc {} {
    expect {
        eof {}
        timeout { tui_die "timeout waiting for the TUI to exit" }
    }
    set st [wait]
    if {[lindex $st 2] != 0} { tui_die "wait() reported an OS error" }
    return [lindex $st 3]
}
