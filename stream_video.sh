#!/bin/sh
# stream_video.sh - Extract streaming URL and play with MPV
# Based on yt-x technique (https://github.com/Benexl/yt-x)
# Usage: ./stream_video.sh <video_id> <video_title>

DIR=$(dirname "$0")
cd "$DIR"

VIDEO_ID="$1"
VIDEO_TITLE="$2"

# Export library path - must include pak's .lib directory
export LD_LIBRARY_PATH="$DIR/.lib:$LD_LIBRARY_PATH"

# Paths to binaries (all inside the pak)
YTDLP="$DIR/yt-dlp"
MPV="$DIR/.bin/mpv"
GPTOKEYB="$DIR/.bin/gptokeyb2"
BB="$DIR/.bin/busybox"
SHOW_MSG="$DIR/show_message"

LOG_FILE="$DIR/youtube.log"

# Logging function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Sanitize title for display (remove special characters)
safe_title=$(printf "%s" "$VIDEO_TITLE" | tr -cd 'a-zA-Z0-9 ._-' | cut -c1-40)
[ -z "$safe_title" ] && safe_title="Video"

log_message "=== Starting stream for: $VIDEO_ID ==="
log_message "Title: $VIDEO_TITLE"
log_message "LD_LIBRARY_PATH: $LD_LIBRARY_PATH"

# Show loading message
"$SHOW_MSG" "Loading Video...|$safe_title" &
MSG_PID=$!

# Extract direct streaming URL using yt-dlp (yt-x technique)
# Format: best video up to 720p with audio, fallback to best available
log_message "Extracting streaming URL..."
STREAM_URL=$("$YTDLP" \
    -f "best[height<=720][ext=mp4]/best[height<=720]/bestvideo[height<=720]+bestaudio/best" \
    --get-url \
    "https://www.youtube.com/watch?v=$VIDEO_ID" 2>> "$LOG_FILE")

# Kill loading message
kill $MSG_PID 2>/dev/null
wait $MSG_PID 2>/dev/null

# Check if URL was extracted
if [ -z "$STREAM_URL" ]; then
    log_message "ERROR: Failed to extract streaming URL"
    "$SHOW_MSG" "Failed to Load Video|Try updating yt-dlp" -l ab -a "UPDATE" -b "BACK"
    if [ $? -eq 0 ]; then
        "$DIR/update_yt_dlp.sh"
    fi
    exit 1
fi

log_message "Stream URL obtained successfully"
log_message "URL length: $(echo "$STREAM_URL" | wc -c) characters"

# Prevent screen sleep during playback
echo 1 > /tmp/stay_awake

# Start controller-to-keyboard mapper for MPV
log_message "Starting gptokeyb2 for MPV..."
"$GPTOKEYB" -1 "mpv" -c "$DIR/keys.gptk" &
GPTK_PID=$!
sleep 0.5

# Show playback starting message briefly
"$SHOW_MSG" "Starting Playback...|$safe_title" -t 1

# Launch MPV with streaming URL
# Cache settings optimized for network streaming
log_message "Launching MPV..."
HOME="$DIR" "$MPV" "$STREAM_URL" \
    --fullscreen \
    --cache=yes \
    --demuxer-max-bytes=50M \
    --demuxer-readahead-secs=20 \
    --network-timeout=30 \
    --audio-buffer=1 \
    --force-seekable=yes \
    --screenshot-directory="/mnt/SDCARD/Screenshots" \
    --screenshot-template="YouTube-%F-%n" \
    2>> "$LOG_FILE"

MPV_EXIT=$?
log_message "MPV exited with code: $MPV_EXIT"

# Cleanup
kill $GPTK_PID 2>/dev/null
wait $GPTK_PID 2>/dev/null
rm -f /tmp/stay_awake

if [ $MPV_EXIT -ne 0 ]; then
    log_message "Playback may have encountered an issue"
fi

log_message "=== Stream ended for: $VIDEO_ID ==="
