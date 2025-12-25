#!/bin/sh
# YouTube Streaming Pak for TrimUI Brick (NextUI)
# Based on yt-x technique (https://github.com/Benexl/yt-x)
# Uses yt-dlp to extract streaming URLs and mpv for playback

DIR=$(dirname "$0")
cd "$DIR"

# Export library path - include all possible library locations
export LD_LIBRARY_PATH="$DIR/.lib:$LD_LIBRARY_PATH"

# Paths to binaries (all inside the pak)
YTDLP="$DIR/yt-dlp"
PICKER="$DIR/picker"
MPV="$DIR/.bin/mpv"
GPTOKEYB="$DIR/.bin/gptokeyb2"
BB="$DIR/.bin/busybox"
SHOW_MSG="$DIR/show_message"
KEYBOARD="$DIR/keyboard"

# Data files
CHANNELS_FILE="$DIR/channels.txt"
LOG_FILE="$DIR/youtube.log"

# Temp files
MENU_FILE="/tmp/yt_menu.txt"
RESULTS_FILE="/tmp/yt_results.txt"

# Create channels file if it doesn't exist
[ ! -f "$CHANNELS_FILE" ] && touch "$CHANNELS_FILE"

# Logging function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

log_message "=== YouTube.pak starting ==="
log_message "DIR: $DIR"
log_message "LD_LIBRARY_PATH: $LD_LIBRARY_PATH"

# Check internet connectivity
check_connectivity() {
    ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 ||
    ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 ||
    ping -c 1 -W 2 208.67.222.222 >/dev/null 2>&1
}

# Search YouTube
search_youtube() {
    log_message "Starting YouTube search"

    # Get search query using keyboard
    query=$("$KEYBOARD" minui.ttf)

    if [ -z "$query" ]; then
        log_message "Search cancelled - empty query"
        return
    fi

    log_message "Searching for: $query"
    "$SHOW_MSG" "Searching YouTube...|$query" &
    MSG_PID=$!

    # Search YouTube using yt-dlp (yt-x technique)
    # Format: title|video_id|stream (for picker)
    "$YTDLP" "ytsearch10:$query" \
        --flat-playlist \
        --no-warnings \
        --print "%(title).50s|%(id)s|stream" \
        2>/dev/null > "$RESULTS_FILE"

    kill $MSG_PID 2>/dev/null

    if [ ! -s "$RESULTS_FILE" ]; then
        log_message "No results found"
        "$SHOW_MSG" "No Results Found" -l a
        return
    fi

    log_message "Found $(wc -l < "$RESULTS_FILE") results"

    # Show results using picker
    while true; do
        selected=$("$PICKER" "$RESULTS_FILE" -a "STREAM" -b "BACK")
        picker_status=$?

        log_message "Picker status: $picker_status, selected: $selected"

        # B button pressed - go back
        [ $picker_status -eq 2 ] && break
        # Other exit
        [ $picker_status -ne 0 ] && break

        if [ -n "$selected" ]; then
            video_title=$(echo "$selected" | cut -d'|' -f1)
            video_id=$(echo "$selected" | cut -d'|' -f2)
            log_message "Selected: $video_title ($video_id)"

            # Stream video directly
            "$DIR/stream_video.sh" "$video_id" "$video_title"
        fi
    done
}

# Browse a saved channel
browse_channel() {
    if [ ! -s "$CHANNELS_FILE" ]; then
        "$SHOW_MSG" "No Channels Saved|Add a channel first" -l a
        return
    fi

    # Create channel menu
    > "$MENU_FILE"
    while read -r channel; do
        [ -n "$channel" ] && echo "@$channel|$channel|channel" >> "$MENU_FILE"
    done < "$CHANNELS_FILE"

    # Show channel list using picker
    selected=$("$PICKER" "$MENU_FILE" -a "SELECT" -b "BACK")
    picker_status=$?

    [ $picker_status -ne 0 ] && return
    [ -z "$selected" ] && return

    channel=$(echo "$selected" | cut -d'|' -f2)
    log_message "Browsing channel: $channel"

    "$SHOW_MSG" "Loading Videos...|@$channel" &
    MSG_PID=$!

    # Fetch latest videos from channel
    "$YTDLP" "https://www.youtube.com/@$channel/videos" \
        --playlist-items 1-10 \
        --flat-playlist \
        --no-warnings \
        --print "%(title).50s|%(id)s|stream" \
        2>/dev/null > "$RESULTS_FILE"

    kill $MSG_PID 2>/dev/null

    if [ ! -s "$RESULTS_FILE" ]; then
        "$SHOW_MSG" "No Videos Found|Check channel name" -l a
        return
    fi

    # Show videos using picker
    while true; do
        selected=$("$PICKER" "$RESULTS_FILE" -a "STREAM" -b "BACK")
        picker_status=$?

        [ $picker_status -eq 2 ] && break
        [ $picker_status -ne 0 ] && break

        if [ -n "$selected" ]; then
            video_title=$(echo "$selected" | cut -d'|' -f1)
            video_id=$(echo "$selected" | cut -d'|' -f2)
            log_message "Selected: $video_title ($video_id)"

            # Stream video directly
            "$DIR/stream_video.sh" "$video_id" "$video_title"
        fi
    done
}

# Add a new channel
add_channel() {
    "$SHOW_MSG" "Enter Channel Name|Format: ChannelName (without @)" -t 2
    channel=$("$KEYBOARD" minui.ttf)

    if [ -z "$channel" ]; then
        return
    fi

    # Clean input - remove @ and spaces
    channel=$(echo "$channel" | sed 's/^@//' | sed 's/ //g')

    # Check if already exists
    if grep -q "^$channel$" "$CHANNELS_FILE"; then
        "$SHOW_MSG" "Channel Already Exists" -l a
        return
    fi

    # Validate channel
    "$SHOW_MSG" "Validating Channel...|@$channel" &
    MSG_PID=$!

    if "$YTDLP" "https://www.youtube.com/@$channel" \
        --playlist-items 1 --skip-download --no-warnings \
        --print "%(channel)s" >/dev/null 2>&1; then

        kill $MSG_PID 2>/dev/null
        echo "$channel" >> "$CHANNELS_FILE"
        log_message "Added channel: $channel"
        "$SHOW_MSG" "Channel Added|@$channel" -l a
    else
        kill $MSG_PID 2>/dev/null
        "$SHOW_MSG" "Channel Not Found|Check the name" -l a
    fi
}

# Remove a channel
remove_channel() {
    if [ ! -s "$CHANNELS_FILE" ]; then
        "$SHOW_MSG" "No Channels to Remove" -l a
        return
    fi

    # Create channel menu for removal
    > "$MENU_FILE"
    while read -r channel; do
        [ -n "$channel" ] && echo "@$channel|$channel|remove" >> "$MENU_FILE"
    done < "$CHANNELS_FILE"

    selected=$("$PICKER" "$MENU_FILE" -a "REMOVE" -b "BACK")
    picker_status=$?

    [ $picker_status -ne 0 ] && return
    [ -z "$selected" ] && return

    channel=$(echo "$selected" | cut -d'|' -f2)

    "$SHOW_MSG" "Remove @$channel?" -l ab -a "YES" -b "NO"
    if [ $? -eq 0 ]; then
        grep -v "^$channel$" "$CHANNELS_FILE" > /tmp/channels_temp.txt
        mv /tmp/channels_temp.txt "$CHANNELS_FILE"
        log_message "Removed channel: $channel"
        "$SHOW_MSG" "Channel Removed" -l a
    fi
}

# Options menu
show_options() {
    > "$MENU_FILE"
    echo "Add Channel|add|action" >> "$MENU_FILE"
    echo "Remove Channel|remove|action" >> "$MENU_FILE"
    echo "Update yt-dlp|update|action" >> "$MENU_FILE"

    selected=$("$PICKER" "$MENU_FILE" -a "SELECT" -b "BACK")
    picker_status=$?

    [ $picker_status -ne 0 ] && return

    action=$(echo "$selected" | cut -d'|' -f2)

    case "$action" in
        "add") add_channel ;;
        "remove") remove_channel ;;
        "update") "$DIR/update_yt_dlp.sh" ;;
    esac
}

# Main menu
main() {
    log_message "YouTube.pak main() started"

    # Check connectivity first
    if ! check_connectivity; then
        log_message "No internet connection"
        "$SHOW_MSG" "No Internet Connection|Please check WiFi" -l a
        exit 1
    fi

    log_message "Internet connection OK"

    while true; do
        # Build main menu
        > "$MENU_FILE"
        echo "Search YouTube|search|action" >> "$MENU_FILE"
        echo "Browse Channels|channels|action" >> "$MENU_FILE"
        echo "Options|options|action" >> "$MENU_FILE"

        # Show main menu with Y for options, B for exit
        selected=$("$PICKER" "$MENU_FILE" -a "SELECT" -b "EXIT")
        picker_status=$?

        log_message "Main menu: status=$picker_status selected=$selected"

        # B button = exit
        [ $picker_status -eq 2 ] && break

        action=$(echo "$selected" | cut -d'|' -f2)

        case "$action" in
            "search") search_youtube ;;
            "channels") browse_channel ;;
            "options") show_options ;;
        esac
    done

    log_message "YouTube.pak exiting"
}

main
