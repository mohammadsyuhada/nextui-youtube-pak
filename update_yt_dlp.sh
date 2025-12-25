#!/bin/sh
############################################################################
# update_yt_dlp.sh
# Checks GitHub for latest yt-dlp release (ARM64), compares versions, updates.
############################################################################

DIR=$(dirname "$0")
cd "$DIR"

# Paths to binaries (all inside the pak)
SHOW_MSG="$DIR/show_message"
WGET="$DIR/wget"

YT_DLP_VERSION_FILE="$DIR/yt-dlp_version.txt"
TEMP_DIR="/tmp/yt_dlp_update"
YTDLP_BIN="$DIR/yt-dlp"

############################################################################
# 1) Simple connectivity check
############################################################################
check_connectivity() {
    ping -c 1 -W 2 8.8.8.8  >/dev/null 2>&1 ||
    ping -c 1 -W 2 1.1.1.1  >/dev/null 2>&1 ||
    ping -c 1 -W 2 208.67.222.222  >/dev/null 2>&1 ||
    ping -c 1 -W 2 114.114.114.114 >/dev/null 2>&1 ||
    ping -c 1 -W 2 119.29.29.29    >/dev/null 2>&1
}

############################################################################
# 2) Compare versions (like 2023.03.04.1)
#    Returns 0 if $1 (ver1) is greater than $2 (ver2).
############################################################################
version_greater() {
    # Convert "2023.03.04.1" -> "2023 03 04 1"
    ver1=$(echo "$1" | tr '.' ' ')
    ver2=$(echo "$2" | tr '.' ' ')

    # Break them into up to 4 parts, defaulting to 0 if missing
    set -- $ver1
    v1a=${1:-0}
    v1b=${2:-0}
    v1c=${3:-0}
    v1d=${4:-0}

    set -- $ver2
    v2a=${1:-0}
    v2b=${2:-0}
    v2c=${3:-0}
    v2d=${4:-0}

    # Compare piece by piece
    if [ "$v1a" -gt "$v2a" ]; then return 0; fi
    if [ "$v1a" -lt "$v2a" ]; then return 1; fi

    if [ "$v1b" -gt "$v2b" ]; then return 0; fi
    if [ "$v1b" -lt "$v2b" ]; then return 1; fi

    if [ "$v1c" -gt "$v2c" ]; then return 0; fi
    if [ "$v1c" -lt "$v2c" ]; then return 1; fi

    if [ "$v1d" -gt "$v2d" ]; then return 0; fi
    return 1
}

############################################################################
# 3) Main update logic
############################################################################
main() {
    if ! check_connectivity; then
        "$SHOW_MSG" "No internet connection|Cannot update yt-dlp" -l a
        exit 1
    fi

    # Current version from file (or 'none' if missing)
    if [ -f "$YT_DLP_VERSION_FILE" ]; then
        CURRENT_VERSION=$(head -n1 "$YT_DLP_VERSION_FILE")
    else
        CURRENT_VERSION="none"
    fi

    # Prepare temp folder
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"

    "$SHOW_MSG" "Checking for new yt-dlp version..." &
    MSG_PID=$!

    # Fetch latest release data from GitHub
    if ! "$WGET" -q -O "$TEMP_DIR/latest" "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"; then
        kill $MSG_PID 2>/dev/null
        "$SHOW_MSG" "Failed to check GitHub" -l a
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    kill $MSG_PID 2>/dev/null

    # Parse the "tag_name" from the JSON
    LATEST_VERSION=$(grep -o '"tag_name": *"[^"]*' "$TEMP_DIR/latest" | cut -d'"' -f4)
    if [ -z "$LATEST_VERSION" ]; then
        "$SHOW_MSG" "Could not parse version" -l a
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    # Compare with local
    if [ "$CURRENT_VERSION" != "none" ]; then
        if ! version_greater "$LATEST_VERSION" "$CURRENT_VERSION"; then
            "$SHOW_MSG" "Already on latest|$CURRENT_VERSION" -l a
            rm -rf "$TEMP_DIR"
            exit 0
        fi
    fi

    # Find the ARM64 ("aarch64") release asset URL
    AARCH64_URL=$(grep -o '"browser_download_url": *"[^"]*yt-dlp_linux_aarch64"' "$TEMP_DIR/latest" | cut -d'"' -f4)
    if [ -z "$AARCH64_URL" ]; then
        "$SHOW_MSG" "No ARM64 binary found" -l a
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    "$SHOW_MSG" "Downloading yt-dlp $LATEST_VERSION..." &
    MSG_PID=$!

    if ! "$WGET" -q -O "$TEMP_DIR/yt-dlp" "$AARCH64_URL"; then
        kill $MSG_PID 2>/dev/null
        "$SHOW_MSG" "Download failed" -l a
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    kill $MSG_PID 2>/dev/null

    chmod +x "$TEMP_DIR/yt-dlp"

    # Optional: back up old binary
    if [ -f "$YTDLP_BIN" ]; then
        mv "$YTDLP_BIN" "$YTDLP_BIN.old"
    fi

    # Move in the new one
    mv "$TEMP_DIR/yt-dlp" "$YTDLP_BIN"

    # Write version to file
    echo "$LATEST_VERSION" > "$YT_DLP_VERSION_FILE"

    rm -rf "$TEMP_DIR"

    "$SHOW_MSG" "Updated to $LATEST_VERSION" -l a
    exit 0
}

main
