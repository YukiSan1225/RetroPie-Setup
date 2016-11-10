#!/usr/bin/env bash

# This file is part of The RetroPie Project
#
# The RetroPie Project is the legal property of its developers, whose names are
# too numerous to list here. Please refer to the COPYRIGHT.md file distributed with this source.
#
# See the LICENSE.md file at the top-level directory of this distribution and
# at https://raw.githubusercontent.com/RetroPie/RetroPie-Setup/master/LICENSE.md
#

# parameters - mode_req command_to_launch savename

# mode_req==0: run command
# mode_req==1: set video mode to 640x480 (4:3) or 720x480 (16:9) @60hz, and run command
# mode_req==4: set video mode to 1024x768 (4:3) or 1280x720 (16:9) @60hz, and run command

# mode_req=="CEA-#": set video mode to CEA mode #
# mode_req=="DMT-#": set video mode to DMT mode #
# mode_req=="PAL/NTSC-RATIO": set mode to SD output with RATIO of 4:3 / 16:10 or 16:9

# note that mode switching only happens if the monitor reports the modes as available (via tvservice)
# and the requested mode differs from the currently active mode

# if savename is included, that is used for loading and saving of video output modes as well as dispmanx settings
# for the current command. If omitted, the binary name is used as a key for the loading and saving. The savename is
# also displayed in the video output menu (detailed below), so for our purposes we send the emulator module id, which
# is somewhat descriptive yet short.

# on launch this script waits for 1 second for a keypress. If x or m is pressed, a menu is displayed allowing
# the user to set a screenmode for this particular command. the savename parameter is displayed to the user - we use the module id
# of the emulator we are launching.

ROOTDIR="/opt/retropie"
CONFIGDIR="$ROOTDIR/configs"
LOG="/dev/shm/runcommand.log"

RUNCOMMAND_CONF="$CONFIGDIR/all/runcommand.cfg"
VIDEO_CONF="$CONFIGDIR/all/videomodes.cfg"
APPS_CONF="$CONFIGDIR/all/emulators.cfg"
DISPMANX_CONF="$CONFIGDIR/all/dispmanx.cfg"
RETRONETPLAY_CONF="$CONFIGDIR/all/retronetplay.cfg"

TVSERVICE="/opt/vc/bin/tvservice"

declare -A MODE_MAP
declare -A MODE

MODE_MAP[1-CEA-4:3]="CEA-1"
MODE_MAP[1-DMT-4:3]="DMT-4"
MODE_MAP[1-CEA-16:9]="CEA-1"

MODE_MAP[4-CEA-4:3]="DMT-16"
MODE_MAP[4-DMT-4:3]="DMT-16"
MODE_MAP[4-CEA-16:9]="CEA-4"

source "$ROOTDIR/lib/inifuncs.sh"

function get_config() {
    if [[ -f "$RUNCOMMAND_CONF" ]]; then
        iniConfig " = " '"' "$RUNCOMMAND_CONF"
        iniGet "governor"
        GOVERNOR="$ini_value"
        iniGet "use_art"
        USE_ART="$ini_value"
        [[ -z "$(which fbi)" ]] && USE_ART=0
        iniGet "DISABLE_JOYSTICK"
        DISABLE_JOYSTICK="$ini_value"
        iniGet "DISABLE_MENU"
        DISABLE_MENU="$ini_value"
        [[ "$DISABLE_MENU" -eq 1 ]] && DISABLE_JOYSTICK=1
    fi

    if [[ -f "$TVSERVICE" ]]; then
        HAS_TVS=1
    else
        HAS_TVS=0
    fi
}

function start_joy2key() {
    [[ "$DISABLE_JOYSTICK" -eq 1 ]] && return
    # get the first joystick device (if not already set)
    [[ -z "$__joy2key_dev" ]] && __joy2key_dev="$(ls -1 /dev/input/js* 2>/dev/null | head -n1)"
    # if joy2key.py is installed run it with cursor keys for axis, and enter + tab for buttons 0 and 1
    if [[ -f "$ROOTDIR/supplementary/runcommand/joy2key.py" && -n "$__joy2key_dev" ]] && ! pgrep -f joy2key.py >/dev/null; then

        # call joy2key.py: arguments are curses capability names or hex values starting with '0x'
        # see: http://pubs.opengroup.org/onlinepubs/7908799/xcurses/terminfo.html
        "$ROOTDIR/supplementary/runcommand/joy2key.py" "$__joy2key_dev" kcub1 kcuf1 kcuu1 kcud1 0x0a 0x09 &
        __joy2key_pid=$!
    fi
}

function stop_joy2key() {
    if [[ -n "$__joy2key_pid" ]]; then
        kill -INT "$__joy2key_pid"
    fi
}


function get_params() {
    mode_req="$1"
    [[ -z "$mode_req" ]] && exit 1

    command="$2"
    [[ -z "$command" ]] && exit 1

    console_out=0
    # if the command is _SYS_, or _PORT_ arg 3 should be system name, and arg 4 rom/game, and we look up the configured system for that combination
    if [[ "$command" == "_SYS_" || "$command" == "_PORT_" ]]; then
        # if the rom is actually a special +Start System.sh script, we should launch the script directly.
        if [[ "$4" =~ \/\+Start\ (.+)\.sh$ ]]; then
            # extract emulator from the name (and lowercase it)
            emulator=${BASH_REMATCH[1],,}
            is_sys=0
            command="bash \"$4\""
            system="$3"
        else
            is_sys=1
            system="$3"
            rom="$4"
            if [[ "$command" == "_PORT_" ]]; then
                conf_root="$CONFIGDIR/ports/$system"
                emu_conf="$conf_root/emulators.cfg"
                is_port=1
            else
                conf_root="$CONFIGDIR/$system"
                emu_conf="$conf_root/emulators.cfg"
                is_port=0
            fi
            get_sys_command "$system" "$rom"
        fi
    else
        is_sys=0
        console_out=1
        emulator="$3"
        # if we have an emulator name (such as module_id) we use that for storing/loading parameters for video output/dispmanx
        # if the parameter is empty we use the name of the binary (to avoid breakage with out of date emulationstation configs)
        [[ -z "$emulator" ]] && emulator="${command/% */}"
    fi

    netplay=0
}

function get_save_vars() {
    # convert emulator name / binary to a names usable as variables in our config files
    save_emu=${emulator//\//_}
    save_emu=${save_emu//[^a-zA-Z0-9_\-]/}
    save_emu_render="${save_emu}_render"
    fb_save_emu="${save_emu}_fb"
    save_rom=r$(echo "$command" | md5sum | cut -d" " -f1)
    fb_save_rom="${save_rom}_fb"
}

function get_all_modes() {
    local group
    for group in CEA DMT; do
        while read -r line; do
            local id=$(echo $line | grep -oE "mode [0-9]*" | cut -d" " -f2)
            local info=$(echo $line | cut -d":" -f2-)
            info=${info/ /}
            if [[ -n "$id" ]]; then
                mode_id+=($group-$id)
                MODE[$group-$id]="$info"
            fi
        done < <($TVSERVICE -m $group)
    done
    local aspect
    for group in "NTSC" "PAL"; do
        for aspect in "4:3" "16:10" "16:9"; do
            mode_id+=($group-$aspect)
            MODE[$group-$aspect]="SDTV - $group-$aspect"
        done
    done
}

function get_mode_info() {
    local status="$1"
    local temp
    local mode_info=()

    # get mode type / id
    if [[ "$status" =~ (PAL|NTSC) ]]; then
        temp=($(echo "$status" | grep -oE "(PAL|NTSC) (4:3|16:10|16:9)"))
    else
        temp=($(echo "$status" | grep -oE "(CEA|DMT) \([0-9]+\)"))
    fi
    mode_info[0]="${temp[0]}"
    mode_info[1]="${temp[1]/[()]/}"

    # get mode resolution
    temp=$(echo "$status" | cut -d"," -f2 | grep -oE "[0-9]+x[0-9]+")
    temp=(${temp/x/ })
    mode_info[2]="${temp[0]}"
    mode_info[3]="${temp[1]}"

    # get aspect ratio
    temp=$(echo "$status" | grep -oE "([0-9]+:[0-9]+)")
    mode_info[4]="$temp"

    # get refresh rate
    temp=$(echo "$status" | grep -oE "[0-9\.]+Hz" | cut -d"." -f1)
    mode_info[5]="$temp"

    echo "${mode_info[@]}"
}

function load_mode_defaults() {
    local temp
    mode_orig=()

    if [[ $HAS_TVS -eq 1 ]]; then
        # get current mode / aspect ratio
        mode_orig=($(get_mode_info "$($TVSERVICE -s)"))
        mode_new=("${mode_orig[@]}")

        # get default mode for requested mode of 1 or 4
        if [[ "$mode_req" == "0" ]]; then
            mode_new_id="${mode_orig[0]}-${mode_orig[1]}"
        elif [[ $mode_req =~ (1|4) ]]; then
            # if current aspect is anything else like 5:4 / 10:9 just choose a 4:3 mode
            local aspect="${mode_orig[4]}"
            [[ "$aspect" =~ (4:3|16:9) ]] || aspect="4:3"
            temp="${mode_req}-${mode_orig[0]}-$aspect"
            mode_new_id="${MODE_MAP[$temp]}"
        else
            mode_new_id="$mode_req"
        fi
    fi

    # get default fb_res (if not running on X)
    fb_orig=""
    if [[ -z "$DISPLAY" ]]; then
        fb_orig="$(fbset)"
        fb_orig="${fb_orig##*mode \"}"
        fb_orig="${fb_orig%%\"*}"
    fi

    mode_def_emu=""
    mode_def_rom=""
    fb_def_emu=""
    fb_def_rom=""

    # default retroarch render res to config file
    render_res="config"

    if [[ -f "$VIDEO_CONF" ]]; then
        # local default video modes for emulator / rom
        iniConfig " = " '"' "$VIDEO_CONF"
        iniGet "$save_emu"
        if [[ -n "$ini_value" ]]; then
            mode_def_emu="$ini_value"
            mode_new_id="$mode_def_emu"
        fi

        iniGet "$save_rom"
        if [[ -n "$ini_value" ]]; then
            mode_def_rom="$ini_value"
            mode_new_id="$mode_def_rom"
        fi

        if [[ -z "$DISPLAY" ]]; then
            # load default framebuffer res for emulator / rom
            iniGet "$fb_save_emu"
            if [[ -n "$ini_value" ]]; then
                fb_def_emu="$ini_value"
                fb_new="$fb_def_emu"
            fi

            iniGet "$fb_save_rom"
            if [[ -n "$ini_value" ]]; then
                fb_def_rom="$ini_value"
                fb_new="$fb_def_rom"
            fi
        fi

        iniGet "$save_emu_render"
        if [[ -n "$ini_value" ]]; then
            render_res="$ini_value"
        fi
    fi
}

function main_menu() {
    local save
    local cmd
    local choice

    [[ -z "$rom_bn" ]] && rom_bn="game/rom"
    [[ -z "$system" ]] && system="emulator/port"

    while true; do

        local options=()
        if [[ $is_sys -eq 1 ]]; then
            options+=(
                1 "Select default emulator for $system ($emulator_def_sys)"
                2 "Select emulator for rom ($emulator_def_rom)"
            )
            [[ -n "$emulator_def_rom" ]] && options+=(3 "Remove emulator choice for rom")
        fi

        if [[ $HAS_TVS -eq 1 ]]; then
            options+=(
                4 "Select default video mode for $emulator ($mode_def_emu)"
                5 "Select video mode for $emulator + rom ($mode_def_rom)"
            )
            [[ -n "$mode_def_emu" ]] && options+=(6 "Remove video mode choice for $emulator")
            [[ -n "$mode_def_rom" ]] && options+=(7 "Remove video mode choice for $emulator + rom")
        fi

        if [[ "$command" =~ retroarch ]]; then
            options+=(
                8 "Select RetroArch render res for $emulator ($render_res)"
                9 "Edit custom RetroArch config for this rom"
            )
        elif [[ -z "$DISPLAY" ]]; then
            options+=(
                10 "Select framebuffer res for $emulator ($fb_def_emu)"
                11 "Select framebuffer res for $emulator + rom ($fb_def_rom)"
            )
            [[ -n "$fb_def_emu" ]] && options+=(12 "Remove framebuffer res choice for $emulator")
            [[ -n "$fb_def_rom" ]] && options+=(13 "Remove framebuffer res choice for $emulator + rom")
        fi

        options+=(X "Launch")

        if [[ "$command" =~ retroarch ]]; then
            options+=(L "Launch with verbose logging")
            options+=(Z "Launch with netplay enabled")
        fi

        options+=(Q "Exit (without launching)")

        local temp_mode
        if [[ $HAS_TVS -eq 1 ]]; then
            temp_mode="${MODE[$mode_new_id]}"
        else
            temp_mode="n/a"
        fi
        cmd=(dialog --nocancel --menu "System: $system\nEmulator: $emulator\nVideo Mode: $temp_mode\nROM: $rom_bn"  22 76 16 )
        choice=$("${cmd[@]}" "${options[@]}" 2>&1 >/dev/tty)
        case $choice in
            1)
                choose_app
                get_save_vars
                load_mode_defaults
                ;;
            2)
                choose_app "$appsave"
                get_save_vars
                load_mode_defaults
                ;;
            3)
                sed -i "/$appsave/d" "$APPS_CONF"
                get_sys_command "$system" "$rom"
                ;;
            4)
                choose_mode "$save_emu" "$mode_def_emu"
                load_mode_defaults
                ;;
            5)
                choose_mode "$save_rom" "$mode_def_rom"
                load_mode_defaults
                ;;
            6)
                sed -i "/$save_emu/d" "$VIDEO_CONF"
                load_mode_defaults
                ;;
            7)
                sed -i "/$save_rom/d" "$VIDEO_CONF"
                load_mode_defaults
                ;;
            8)
                choose_render_res "$save_emu_render"
                ;;
            9)
                touch "$rom.cfg"
                cmd=(dialog --editbox "$rom.cfg" 22 76)
                choice=$("${cmd[@]}" 2>&1 >/dev/tty)
                [[ -n "$choice" ]] && echo "$choice" >"$rom.cfg"
                [[ ! -s "$rom.cfg" ]] && rm "$rom.cfg"
                ;;
            10)
                choose_fb_res "$fb_save_emu" "$fb_def_emu"
                load_mode_defaults
                ;;
            11)
                choose_fb_res "$fb_save_rom" "$fb_def_rom"
                load_mode_defaults
                ;;
            12)
                sed -i "/$fb_save_emu/d" "$VIDEO_CONF"
                load_mode_defaults
                ;;
            13)
                sed -i "/$fb_save_rom/d" "$VIDEO_CONF"
                load_mode_defaults
                ;;
            Z)
                netplay=1
                break
                ;;
            X)
                return 0
                ;;
            L)
                command+=" --verbose"
                return 0
                ;;
            Q)
                return 1
                ;;
        esac
    done
    return 0
}

function choose_mode() {
    local save="$1"
    local default="$2"
    options=()
    local key
    for key in ${mode_id[@]}; do
        options+=("$key" "${MODE[$key]}")
    done
    local cmd=(dialog --default-item "$default" --menu "Choose video output mode"  22 76 16 )
    mode_new_id=$("${cmd[@]}" "${options[@]}" 2>&1 >/dev/tty)
    [[ -z "$mode_new_id" ]] && return

    iniConfig " = " '"' "$VIDEO_CONF"
    iniSet "$save" "$mode_new_id"
}

function choose_app() {
    local save="$1"
    local default
    local default_id
    if [[ -n "$save" ]]; then
        default="$emulator"
    else
        default="$emulator_def_sys"
    fi
    local options=()
    local i=1
    while read line; do
        # convert key=value to array
        local line=(${line/=/ })
        local id=${line[0]}
        [[ "$id" == "default" ]] && continue
        local apps[$i]="$id"
        if [[ "$id" == "$default" ]]; then
            default_id="$i"
        fi
        options+=($i "$id")
        ((i++))
    done < <(sort "$emu_conf")
    if [[ -z "${options[*]}" ]]; then
        dialog --msgbox "No emulator options found for $system - have you installed any snes emulators yet? Do you have a valid $emu_conf ?" 20 60 >/dev/tty
        exit 1
    fi
    local cmd=(dialog --default-item "$default_id" --menu "Choose default emulator"  22 76 16 )
    local choice=$("${cmd[@]}" "${options[@]}" 2>&1 >/dev/tty)
    if [[ -n "$choice" ]]; then
        if [[ -n "$save" ]]; then
            iniConfig " = " '"' "$APPS_CONF"
            iniSet "$save" "${apps[$choice]}"
        else
            iniConfig " = " '"' "$emu_conf"
            iniSet "default" "${apps[$choice]}"
        fi
        get_sys_command "$system" "$rom"
    fi
}

function choose_render_res() {
    local save="$1"
    local res=(
        "320x240"
        "640x480"
        "800x600"
        "960x720"
        "1280x960"
    )
    local i=1
    local item
    local options=()
    for item in "${res[@]}"; do
        options+=($i "$item")
        ((i++))
    done
    options+=(
        O "Use video output resolution"
        C "Use config file resolution"
    )
    local cmd=(dialog --menu "Choose RetroArch render resolution" 22 76 16 )
    local choice=$("${cmd[@]}" "${options[@]}" 2>&1 >/dev/tty)
    [[ -z "$choice" ]] && return
    case "$choice" in
        O)
            render_res="output"
            ;;
        C)
            render_res="config"
            ;;
        *)
            render_res="${res[$choice-1]}"
            ;;
    esac

    iniConfig " = " '"' "$VIDEO_CONF"
    iniSet "$save" "$render_res"
}

function choose_fb_res() {
    local save="$1"
    local default="$2"
    local res=(
        "320x240"
        "640x480"
        "960x720"
        "1280x960"
    )
    local i=1
    local item
    local options=()
    for item in "${res[@]}"; do
        options+=($i "$item")
        ((i++))
    done
    local cmd=(dialog --default-item "$default" --menu "Choose framebuffer resolution (Useful for X and console apps)" 22 76 16 )
    local choice=$("${cmd[@]}" "${options[@]}" 2>&1 >/dev/tty)
    [[ -z "$choice" ]] && return
    fb_res="${res[$choice-1]}"

    iniConfig " = " '"' "$VIDEO_CONF"
    iniSet "$save" "$fb_res"
}

function switch_fb_res() {
    local res=(${1/x/ })
    local res_x=${res[0]}
    local res_y=${res[1]}
    if [[ -z "$res_x" || -z "$res_y" ]]; then
        fbset --all -depth 8
        fbset --all -depth 16
    else
        fbset --all -depth 8
        fbset --all --geometry $res_x $res_y $res_x $res_y 16
    fi
}

function switch_mode() {
    local mode_id="$1"

    # if the requested mode is the same as the current mode don't switch
    [[ "$mode_id" == "${mode_orig[0]}-${mode_orig[1]}" ]] && return 0

    local mode_id=(${mode_id/-/ })

    local switched=0
    if [[ "${mode_id[0]}" == "PAL" ]] || [[ "${mode_id[0]}" == "NTSC" ]]; then
        $TVSERVICE -c "${mode_id[*]}"
        switched=1
    else
        local has_mode=$($TVSERVICE -m ${mode_id[0]} | grep -w "mode ${mode_id[1]}")
        if [[ -n "${mode_id[*]}" ]] && [[ -n "$has_mode" ]]; then
            $TVSERVICE -e "${mode_id[*]}"
            switched=1
        fi
    fi

    # if we have switched mode, switch the framebuffer resolution also
    if [[ $switched -eq 1 ]]; then
        sleep 1
        mode_new=($(get_mode_info "$($TVSERVICE -s)"))
        [[ -z "$fb_new" ]] && fb_new="${mode_new[2]}x${mode_new[3]}"
    fi

    return $switched
}

function restore_mode() {
    local mode=(${1/-/ })
    if [[ "${MODE[0]}" == "PAL" ]] || [[ "${MODE[0]}" == "NTSC" ]]; then
        $TVSERVICE -c "${mode[*]}"
    else
        $TVSERVICE -p
    fi
}

function restore_fb() {
    sleep 1
    switch_fb_res "$fb_orig"
}

function config_dispmanx() {
    local name="$1"
    # if we have a dispmanx conf file and $name is in it (as a variable) and set to 1,
    # change the library path to load dispmanx sdl first
    if [[ -f "$DISPMANX_CONF" ]]; then
        iniConfig " = " '"' "$DISPMANX_CONF"
        iniGet "$name"
        [[ "$ini_value" == "1" ]] && command="SDL1_VIDEODRIVER=dispmanx $command"
    fi
}

function retroarch_append_config() {
    # only for retroarch emulators
    [[ ! "$command" =~ "retroarch" ]] && return

    # make sure tmp folder exists for unpacking archives
    mkdir -p "/tmp/retroarch"

    local conf="/dev/shm/retroarch.cfg"
    rm -f "$conf"
    touch "$conf"
    if [[ "$HAS_TVS" -eq 1 && "${mode_new[5]}" -gt 0 ]]; then
        # set video_refresh_rate in our config to the same as the screen refresh
        [[ -n "${mode_new[5]}" ]] && echo "video_refresh_rate = ${mode_new[5]}" >>"$conf"
    fi

    local dim
    # if our render resolution is "config", then we don't set anything (use the value in the retroarch.cfg)
    if [[ "$render_res" != "config" ]]; then
        if [[ "$render_res" == "output" ]]; then
            dim=(0 0)
        else
            dim=(${render_res/x/ })
        fi
        echo "video_fullscreen_x = ${dim[0]}" >>"$conf"
        echo "video_fullscreen_y = ${dim[1]}" >>"$conf"
    fi

    # if the rom has a custom configuration then append that too
    if [[ -f "$rom.cfg" ]]; then
        conf+="'|'\"$rom.cfg\""
    fi

    # if we already have an existing appendconfig parameter, we need to add our configs to that
    if [[ "$command" =~ "--appendconfig" ]]; then
        command=$(echo "$command" | sed "s#\(--appendconfig *[^ $]*\)#\1'|'$conf#")
    else
        command+=" --appendconfig $conf"
    fi

    # append any netplay configuration
    if [[ $netplay -eq 1 ]] && [[ -f "$RETRONETPLAY_CONF" ]]; then
        source "$RETRONETPLAY_CONF"
        command+=" -$__netplaymode $__netplayhostip_cfile --port $__netplayport --frames $__netplayframes --nick $__netplaynickname"
    fi
}

function set_governor() {
    governor_old=()
    # we save the previous states first, as setting any cpuX on the RPI will also set the value for the other cores
    # which would cause us to save the wrong state for cpu1/2/3 after setting cpu0. On the RPI we could just process
    # cpu0, but this code needs to work on other platforms that do support a "per core" CPU governor.
    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        governor_old+=($(<$cpu))
    done
    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        echo "$1" | sudo tee "$cpu" >/dev/null
    done
}

function restore_governor() {
    local i=0
    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        echo "${governor_old[$i]}" | sudo tee "$cpu" >/dev/null
        ((i++))
    done
}

function get_sys_command() {
    local system="$1"
    local rom="$2"

    rom_bn="${rom##*/}"
    rom_bn="${rom_bn%.*}"

    appsave=a$(echo "$system$rom" | md5sum | cut -d" " -f1)

    if [[ ! -f "$emu_conf" ]]; then
        echo "No config found for system $system"
        exit 1
    fi

    iniConfig " = " '"' "$emu_conf"
    iniGet "default"
    if [[ -z "$ini_value" ]]; then
        echo "No default emulator found for system $system"
        start_joy2key
        choose_app
        stop_joy2key
        get_sys_command "$system" "$rom"
        return
    fi

    emulator="$ini_value"
    emulator_def_sys="$emulator"

    # get system & rom specific app if set
    if [[ -f "$APPS_CONF" ]]; then
        iniConfig " = " '"' "$APPS_CONF"
        iniGet "$appsave"
        emulator_def_rom="$ini_value"
        [[ -n "$ini_value" ]] && emulator="$ini_value"
    fi

    # get the app commandline
    iniConfig " = " '"' "$emu_conf"
    iniGet "$emulator"
    command="$ini_value"

    # replace tokens
    command="${command/\%ROM\%/\"$rom\"}"
    command="${command/\%BASENAME\%/\"$rom_bn\"}"

    # special case to get the last 2 folders for quake games for the -game parameter
    # remove everything up to /quake/
    local quake_dir="${rom##*/quake/}"
    # remove filename
    local quake_dir="${quake_dir%/*}"
    command="${command/\%QUAKEDIR\%/\"$quake_dir\"}"

    # if it starts with CON: it is a console application (so we don't redirect stdout later)
    if [[ "$command" == CON:* ]]; then
        # remove CON:
        command="${command:4}"
        console_out=1
    fi
}

function show_launch() {
    local images=()

    if [[ "$USE_ART" -eq 1 ]]; then
        # if using art look for images in paths for es art.
        images+=(
            "$HOME/RetroPie/roms/$system/images/${rom_bn}-image"
            "$HOME/.emulationstation/downloaded_images/$system/${rom_bn}-image"
        )
    fi

    # look for custom launching images
    [[ $is_sys -eq 1 ]] && images+=("$conf_root/launching")
    [[ $is_port -eq 1 ]] && images+=("$CONFIGDIR/ports/launching")
    images+=(
        "$CONFIGDIR/all/launching"
    )

    local image
    local path
    local ext
    for path in "${images[@]}"; do
        for ext in jpg png; do
            if [[ -f "$path.$ext" ]]; then
                image="$path.$ext"
                break 2
            fi
        done
    done

    if [[ -z "$DISPLAY" && -n "$image" ]]; then
        fbi -1 -t 2 -noverbose -a "$image" </dev/tty &>/dev/null
    elif [[ "$DISABLE_MENU" -ne 1 && "$USE_ART" -ne 1 ]]; then
        local launch_name
        if [[ -n "$rom_bn" ]]; then
            launch_name="$rom_bn ($emulator)"
        else
            launch_name="$emulator"
        fi
        DIALOGRC="$CONFIGDIR/all/runcommand-launch-dialog.cfg" dialog --infobox "\nLaunching $launch_name ...\n\nPress a button to configure\n\nErrors are logged to $LOG" 9 60
    fi
}

function check_menu() {
    local dont_launch=0
    start_joy2key
    # check for key pressed to enter configuration
    IFS= read -s -t 2 -N 1 key </dev/tty
    if [[ -n "$key" ]]; then
        if [[ $HAS_TVS -eq 1 ]]; then
            get_all_modes
        fi
        tput cnorm
        main_menu
        dont_launch=$?
        tput civis
        clear
    fi
    stop_joy2key
    return $dont_launch
}

# calls script with parameters system, emulator, rom, and commandline
function user_script() {
    local script="$CONFIGDIR/all/$1"
    if [[ -f "$script" ]]; then
        bash "$script" "$system" "$emulator" "$rom" "$command" </dev/tty 2>>"$LOG"
    fi
}

get_config

get_params "$@"

# turn off cursor and clear screen
tput civis
clear

rm -f "$LOG"
echo -e "$system\n$emulator\n$rom\n$command" >/dev/shm/runcommand.info
user_script "runcommand-onstart.sh"

get_save_vars

load_mode_defaults

show_launch

if [[ "$DISABLE_MENU" -ne 1 ]]; then
    if ! check_menu; then
        tput cnorm
        exit 0
    fi
fi

if [[ $HAS_TVS -eq 1 ]]; then
    switch_mode "$mode_new_id"
    switched=$?
else
    switched=0
fi

[[ -n "$fb_new" ]] && switch_fb_res "$fb_new"

config_dispmanx "$save_emu"

# switch to configured cpu scaling governor
[[ -n "$GOVERNOR" ]] && set_governor "$GOVERNOR"

retroarch_append_config

# launch the command
echo -e "Parameters: $@\nExecuting: $command" >>"$LOG"
if [[ "$console_out" -eq 1 ]]; then
    # turn cursor on
    tput cnorm
    eval $command </dev/tty 2>>"$LOG"
    tput civis
else
    eval $command </dev/tty &>>"$LOG"
fi

clear

# remove tmp folder for unpacked archives if it exists
rm -rf "/tmp/retroarch"

# restore default cpu scaling governor
[[ -n "$GOVERNOR" ]] && restore_governor

# if we switched mode - restore preferred mode
if [[ $switched -eq 1 ]]; then
    restore_mode "$mode_cur"
fi

# reset/restore framebuffer res (if it was changed)
[[ -n "$fb_new" ]] && restore_fb

[[ "$command" =~ retroarch ]] && retroarchIncludeToEnd "$conf_root/retroarch.cfg"

user_script "runcommand-onend.sh"

exit 0
