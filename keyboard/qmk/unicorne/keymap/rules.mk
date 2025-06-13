
# ENABLE_ := yes
ENABLE_RGB_MATRIX := yes
ENABLE_TAP_DANCE := yes
ENABLE_JOYSTICK := yes
ENABLE_COMBO := yes
ENABLE_WPM := no
ENABLE_OLED := yes

# NOTE: OLED display function, only one function is yes
ENABLE_QMK_LOGO := no
ENABLE_BONGOCAT := yes

# === Conditional module loading ===
ifeq ($(strip $(ENABLE_RGB_MATRIX)), yes)
    RGB_MATRIX_ENABLE = yes
endif

ifeq ($(strip $(ENABLE_TAP_DANCE)), yes)
    TAP_DANCE_ENABLE = yes
endif

ifeq ($(strip $(ENABLE_JOYSTICK)), yes)
    JOYSTICK_ENABLE = yes
endif

ifeq ($(strip $(ENABLE_COMBO)), yes)
    COMBO_ENABLE = yes
endif

ifeq ($(strip $(ENABLE_WPM)), yes)
    WPM_ENABLE = yes
endif

ifeq ($(strip $(ENABLE_OLED)), yes)
    OLED_DRIVER_ENABLE = yes
    ifeq ($(strip $(ENABLE_QMK_LOGO)), yes)
        OPT_DEFS += -DENABLE_QMK_LOGO=1
    else ifeq ($(strip $(ENABLE_BONGOCAT)), yes)
        OPT_DEFS += -DENABLE_BONGOCAT=1
        WPM_ENABLE = yes
    endif
endif
