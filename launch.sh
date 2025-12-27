#!/bin/sh
# YouTube Streaming Pak for TrimUI Brick (NextUI)
# Based on yt-x technique (https://github.com/Benexl/yt-x)
# Uses yt-dlp to extract streaming URLs and mpv for playback
# UI: minui-list for menus, minui-presenter for video thumbnails

PAK_DIR="$(dirname "$0")"
PAK_NAME="$(basename "$PAK_DIR")"
PAK_NAME="${PAK_NAME%.*}"

# Setup logging - log to pak folder
LOG_FILE="$PAK_DIR/youtube.log"
rm -f "$LOG_FILE"
exec >>"$LOG_FILE" 2>&1

echo "$0" "$@"
cd "$PAK_DIR" || exit 1

# Detect architecture
architecture=arm
if uname -m | grep -q '64'; then
    architecture=arm64
fi

# Handle platform detection
if [ "$PLATFORM" = "tg3040" ] && [ -z "$DEVICE" ]; then
    export DEVICE="brick"
    export PLATFORM="tg5040"
fi

# Export library and binary paths
export LD_LIBRARY_PATH="$PAK_DIR/.lib:$PAK_DIR/lib/$PLATFORM:$LD_LIBRARY_PATH"
export PATH="$PAK_DIR/bin/$architecture:$PAK_DIR/bin/$PLATFORM:$PAK_DIR:$PAK_DIR/.bin:$PATH"

# Paths to binaries (all inside the pak)
YTDLP="$PAK_DIR/yt-dlp"
MPV="$PAK_DIR/.bin/mpv"
GPTOKEYB="$PAK_DIR/.bin/gptokeyb2"
KEYBOARD="$PAK_DIR/keyboard"
WGET="$PAK_DIR/wget"

# Data files
CHANNELS_FILE="$PAK_DIR/channels.txt"

# Temp files
MENU_FILE="/tmp/yt_menu.txt"
RESULTS_FILE="/tmp/yt_results.txt"
THUMBS_DIR="/tmp/yt_thumbs"
VIDEOS_JSON="/tmp/yt_videos.json"
OUTPUT_JSON="/tmp/yt_output.json"

# Create channels file if it doesn't exist
[ ! -f "$CHANNELS_FILE" ] && touch "$CHANNELS_FILE"

# Cleanup function
cleanup() {
    rm -f /tmp/stay_awake
    rm -rf "$THUMBS_DIR"
    rm -f "$MENU_FILE" "$RESULTS_FILE" "$VIDEOS_JSON" "$OUTPUT_JSON"
    rm -f /tmp/yt_list_output.json
    killall minui-presenter >/dev/null 2>&1 || true
}

# Setup binaries permissions
setup_binaries() {
    chmod +x "$PAK_DIR/bin/$PLATFORM/minui-list" 2>/dev/null
    chmod +x "$PAK_DIR/bin/$PLATFORM/minui-presenter" 2>/dev/null
    chmod +x "$PAK_DIR/bin/$architecture/jq" 2>/dev/null
    chmod +x "$YTDLP" 2>/dev/null
    chmod +x "$KEYBOARD" 2>/dev/null
    chmod +x "$WGET" 2>/dev/null
}

# Show message using minui-presenter
show_message() {
    message="$1"
    seconds="${2:-2}"

    killall minui-presenter >/dev/null 2>&1 || true
    echo "$message" 1>&2

    if [ "$seconds" = "forever" ]; then
        minui-presenter --message "$message" --timeout -1 &
    else
        minui-presenter --message "$message" --timeout "$seconds"
    fi
}

# Show message in background (non-blocking)
show_message_async() {
    message="$1"

    killall minui-presenter >/dev/null 2>&1 || true
    echo "$message" 1>&2
    minui-presenter --message "$message" --timeout -1 &
}

# Show confirmation dialog
show_confirm() {
    message="$1"

    killall minui-presenter >/dev/null 2>&1 || true
    echo "Confirm: $message" 1>&2

    minui-presenter --message "$message" \
        --confirm-show \
        --confirm-text "YES" \
        --cancel-show \
        --cancel-text "NO" \
        --timeout 0

    return $?
}

# Show list menu using minui-list (returns selection via stdout)
show_list() {
    file="$1"
    title="$2"
    confirm_text="${3:-SELECT}"
    cancel_text="${4:-BACK}"

    killall minui-presenter >/dev/null 2>&1 || true

    minui-list \
        --file "$file" \
        --format text \
        --title "$title" \
        --confirm-text "$confirm_text" \
        --cancel-text "$cancel_text"
}

# Download a single thumbnail by video ID
download_thumbnail() {
    video_id="$1"

    mkdir -p "$THUMBS_DIR"
    thumb_path="$THUMBS_DIR/${video_id}.jpg"

    # Skip if already exists
    [ -s "$thumb_path" ] && return 0

    thumb_url="https://i.ytimg.com/vi/${video_id}/mqdefault.jpg"

    echo "Downloading thumbnail: $video_id"
    "$WGET" -q -T 3 -t 1 -O "$thumb_path" "$thumb_url" 2>/dev/null || true

    # Check success
    [ -s "$thumb_path" ] && return 0
    rm -f "$thumb_path" 2>/dev/null
    return 1
}

# Escape string for JSON
escape_json() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/ /g' | tr '\n' ' '
}

# Generate single-item JSON for current video
generate_single_item_json() {
    title="$1"
    video_id="$2"
    current="$3"
    total="$4"
    json_file="$5"

    thumb_path="$THUMBS_DIR/${video_id}.jpg"
    safe_title=$(escape_json "$title")

    # Create JSON with single item
    if [ -s "$thumb_path" ]; then
        cat > "$json_file" << EOF
{"items":[{"text":"[$current/$total] $safe_title","background_image":"$thumb_path","alignment":"top","show_pill":false}],"selected":0}
EOF
    else
        cat > "$json_file" << EOF
{"items":[{"text":"[$current/$total] $safe_title","alignment":"top","show_pill":false}],"selected":0}
EOF
    fi
}

# Browse videos with lazy-loading carousel
# X = Next, Y = Previous, A = Stream, B = Back
browse_videos_carousel() {
    results_file="$1"

    total=$(wc -l < "$results_file" | tr -d ' ')
    echo "browse_videos_carousel: total=$total"
    [ "$total" -eq 0 ] && return

    current_index=0
    mkdir -p "$THUMBS_DIR"

    while true; do
        # Get current video info (1-indexed for sed)
        line=$(sed -n "$((current_index + 1))p" "$results_file")
        [ -z "$line" ] && break

        video_title=$(echo "$line" | cut -d'|' -f1)
        video_id=$(echo "$line" | cut -d'|' -f2)

        echo "Showing video $((current_index + 1))/$total: $video_title"

        # Download thumbnail for current video (lazy load)
        killall minui-presenter >/dev/null 2>&1 || true
        minui-presenter --message "Loading..." --timeout -1 &
        download_thumbnail "$video_id"
        killall minui-presenter >/dev/null 2>&1 || true

        # Generate JSON for current video
        generate_single_item_json "$video_title" "$video_id" "$((current_index + 1))" "$total" "$VIDEOS_JSON"

        # Show presenter with navigation buttons
        # A = Stream, B = Back, X = Next, Y = Prev
        minui-presenter \
            --file "$VIDEOS_JSON" \
            --confirm-show \
            --confirm-text "STREAM" \
            --cancel-show \
            --cancel-text "BACK" \
            --action-show \
            --action-text "NEXT" \
            --action-button "X" \
            --inaction-show \
            --inaction-text "PREV" \
            --inaction-button "Y" \
            --timeout 0

        status=$?
        echo "Presenter status: $status"

        case $status in
            0)  # A button - Stream
                echo "Streaming: $video_title ($video_id)"
                "$PAK_DIR/stream_video.sh" "$video_id" "$video_title"
                ;;
            2)  # B button - Back to menu
                echo "Going back to menu"
                break
                ;;
            4)  # Action (R1) - Next
                echo "Next video"
                if [ $current_index -lt $((total - 1)) ]; then
                    current_index=$((current_index + 1))
                else
                    current_index=0  # Wrap to beginning
                fi
                ;;
            5)  # Inaction (L1) - Previous
                echo "Previous video"
                if [ $current_index -gt 0 ]; then
                    current_index=$((current_index - 1))
                else
                    current_index=$((total - 1))  # Wrap to end
                fi
                ;;
            *)  # Other (menu button, etc)
                echo "Exit with status $status"
                break
                ;;
        esac
    done

    cleanup_thumbnails
}

# Generate JSON for minui-presenter
generate_presenter_json() {
    results_file="$1"
    json_file="$2"

    # Start JSON array
    echo '[' > "$json_file"

    first=true
    while IFS='|' read -r title video_id type; do
        [ -z "$video_id" ] && continue

        thumb_path="$THUMBS_DIR/${video_id}.jpg"

        # Skip if thumbnail doesn't exist or is empty
        [ ! -s "$thumb_path" ] && continue

        # Add comma for non-first items
        if [ "$first" = "true" ]; then
            first=false
        else
            echo ',' >> "$json_file"
        fi

        # Escape title for JSON
        safe_title=$(escape_json "$title")

        # Create JSON object for this video
        cat >> "$json_file" << EOF
{
  "message": "$safe_title",
  "background_image": "$thumb_path",
  "alignment": "bottom",
  "show_pill": true
}
EOF
    done < "$results_file"

    echo ']' >> "$json_file"
}

# Show video presenter with thumbnails
show_video_presenter() {
    json_file="$1"

    killall minui-presenter >/dev/null 2>&1 || true

    minui-presenter \
        --file "$json_file" \
        --confirm-show \
        --confirm-text "STREAM" \
        --cancel-show \
        --cancel-text "BACK" \
        --timeout 0 \
        --write-location "$OUTPUT_JSON" \
        --write-value state

    return $?
}

# Get selected video index from presenter output
get_selected_index() {
    if [ -f "$OUTPUT_JSON" ]; then
        jq -r '.selected // 0' "$OUTPUT_JSON" 2>/dev/null
    else
        echo "0"
    fi
}

# Cleanup thumbnails
cleanup_thumbnails() {
    rm -rf "$THUMBS_DIR"
    rm -f "$VIDEOS_JSON" "$OUTPUT_JSON"
}

# Check internet connectivity
check_connectivity() {
    ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 ||
    ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 ||
    ping -c 1 -W 2 208.67.222.222 >/dev/null 2>&1
}

# Search YouTube
search_youtube() {
    echo "Starting YouTube search"

    # Get search query using keyboard
    query=$("$KEYBOARD" minui.ttf)

    if [ -z "$query" ]; then
        echo "Search cancelled - empty query"
        return
    fi

    echo "Searching for: $query"
    show_message_async "Searching YouTube... | $query"

    # Search YouTube using yt-dlp (yt-x technique)
    # Format: title|video_id|stream
    "$YTDLP" "ytsearch10:$query" \
        --flat-playlist \
        --no-warnings \
        --print "%(title).50s|%(id)s|stream" \
        2>/dev/null > "$RESULTS_FILE"

    if [ ! -s "$RESULTS_FILE" ]; then
        echo "No results found"
        killall minui-presenter >/dev/null 2>&1 || true
        show_message "No Results Found" 2
        return
    fi

    echo "Found $(wc -l < "$RESULTS_FILE") results"
    killall minui-presenter >/dev/null 2>&1 || true

    # Show video carousel with thumbnails
    browse_videos_carousel "$RESULTS_FILE"
}

# Browse a saved channel
browse_channel() {
    if [ ! -s "$CHANNELS_FILE" ]; then
        show_message "No Channels Saved | Add a channel first" 2
        return
    fi

    # Create channel menu
    > "$MENU_FILE"
    while read -r channel; do
        [ -n "$channel" ] && echo "@$channel" >> "$MENU_FILE"
    done < "$CHANNELS_FILE"

    # Show channel list using minui-list
    killall minui-presenter >/dev/null 2>&1 || true
    selected=$(minui-list --file "$MENU_FILE" --format text --title "Select Channel" --confirm-text "SELECT" --cancel-text "BACK")
    exit_code=$?

    [ $exit_code -ne 0 ] && return
    [ -z "$selected" ] && return

    # Extract channel name (remove @ prefix)
    channel=$(echo "$selected" | sed 's/^@//')
    echo "Browsing channel: $channel"

    show_message_async "Loading Videos... | @$channel"

    # Fetch latest videos from channel
    "$YTDLP" "https://www.youtube.com/@$channel/videos" \
        --playlist-items 1-10 \
        --flat-playlist \
        --no-warnings \
        --print "%(title).50s|%(id)s|stream" \
        2>/dev/null > "$RESULTS_FILE"

    if [ ! -s "$RESULTS_FILE" ]; then
        killall minui-presenter >/dev/null 2>&1 || true
        show_message "No Videos Found|Check channel name" 2
        return
    fi

    echo "Found $(wc -l < "$RESULTS_FILE") videos"
    killall minui-presenter >/dev/null 2>&1 || true

    # Show video carousel with thumbnails
    browse_videos_carousel "$RESULTS_FILE"
}

# Add a new channel
add_channel() {
    show_message "Enter Channel Name | Format: ChannelName (without @)" 2
    channel=$("$KEYBOARD" minui.ttf)

    if [ -z "$channel" ]; then
        return
    fi

    # Clean input - remove @ and spaces
    channel=$(echo "$channel" | sed 's/^@//' | sed 's/ //g')

    # Check if already exists
    if grep -q "^$channel$" "$CHANNELS_FILE"; then
        show_message "Channel Already Exists" 2
        return
    fi

    # Validate channel
    show_message_async "Validating Channel... | @$channel"

    if "$YTDLP" "https://www.youtube.com/@$channel" \
        --playlist-items 1 --skip-download --no-warnings \
        --print "%(channel)s" >/dev/null 2>&1; then

        killall minui-presenter >/dev/null 2>&1 || true
        echo "$channel" >> "$CHANNELS_FILE"
        echo "Added channel: $channel"
        show_message "Channel Added | @$channel" 2
    else
        killall minui-presenter >/dev/null 2>&1 || true
        show_message "Channel Not Found | Check the name" 2
    fi
}

# Remove a channel
remove_channel() {
    if [ ! -s "$CHANNELS_FILE" ]; then
        show_message "No Channels to Remove" 2
        return
    fi

    # Create channel menu for removal
    > "$MENU_FILE"
    while read -r channel; do
        [ -n "$channel" ] && echo "@$channel" >> "$MENU_FILE"
    done < "$CHANNELS_FILE"

    killall minui-presenter >/dev/null 2>&1 || true
    selected=$(minui-list --file "$MENU_FILE" --format text --title "Remove Channel" --confirm-text "REMOVE" --cancel-text "BACK")
    exit_code=$?

    [ $exit_code -ne 0 ] && return
    [ -z "$selected" ] && return

    channel=$(echo "$selected" | sed 's/^@//')

    if show_confirm "Remove @$channel?"; then
        grep -v "^$channel$" "$CHANNELS_FILE" > /tmp/channels_temp.txt
        mv /tmp/channels_temp.txt "$CHANNELS_FILE"
        echo "Removed channel: $channel"
        show_message "Channel Removed" 2
    fi
}

# Options menu
show_options() {
    > "$MENU_FILE"
    echo "Add Channel" >> "$MENU_FILE"
    echo "Remove Channel" >> "$MENU_FILE"
    echo "Update yt-dlp" >> "$MENU_FILE"

    killall minui-presenter >/dev/null 2>&1 || true
    selected=$(minui-list --file "$MENU_FILE" --format text --title "Options" --confirm-text "SELECT" --cancel-text "BACK")
    exit_code=$?

    [ $exit_code -ne 0 ] && return

    case "$selected" in
        "Add Channel") add_channel ;;
        "Remove Channel") remove_channel ;;
        "Update yt-dlp") "$PAK_DIR/update_yt_dlp.sh" ;;
    esac
}

# Main menu
main() {
    echo "YouTube.pak main() started"
    echo "1" > /tmp/stay_awake

    # Setup cleanup trap
    trap "cleanup" EXIT INT TERM HUP QUIT

    # Setup binaries
    setup_binaries

    # Check for required tools
    if ! command -v minui-list >/dev/null 2>&1; then
        show_message "minui-list not found" 2
        return 1
    fi

    if ! command -v minui-presenter >/dev/null 2>&1; then
        show_message "minui-presenter not found" 2
        return 1
    fi

    # Check connectivity first
    if ! check_connectivity; then
        echo "No internet connection"
        show_message "No Internet Connection | Please check WiFi" 2
        exit 1
    fi

    echo "Internet connection OK"

    while true; do
        # Build main menu
        > "$MENU_FILE"
        echo "Search YouTube" >> "$MENU_FILE"
        echo "Browse Channels" >> "$MENU_FILE"
        echo "Options" >> "$MENU_FILE"

        # Show main menu
        killall minui-presenter >/dev/null 2>&1 || true
        selected=$(minui-list --file "$MENU_FILE" --format text --title "YouTube" --confirm-text "SELECT" --cancel-text "EXIT")
        exit_code=$?

        echo "Main menu: status=$exit_code selected=$selected"

        # B button or other exit = exit
        [ $exit_code -ne 0 ] && break

        case "$selected" in
            "Search YouTube") search_youtube ;;
            "Browse Channels") browse_channel ;;
            "Options") show_options ;;
        esac
    done

    echo "YouTube.pak exiting"
}

main "$@"
