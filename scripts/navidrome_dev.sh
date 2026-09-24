#!/bin/bash
# Local Navidrome with a generated test library, for developing and testing
# the Navidrome integration. Everything lives in .navidrome-dev (git-ignored).
#
#   scripts/navidrome_dev.sh        # generate library if needed, run the server
#   Server: http://localhost:4533   user: admin   password: admin
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=.navidrome-dev
MUSIC=$ROOT/music
PORT=${ND_PORT:-4533}

tone() {  # tone <file> <frequency> <seconds> <artist> <album> <title> <track> <codec args...>
    local file=$1 freq=$2 secs=$3 artist=$4 album=$5 title=$6 track=$7
    shift 7
    [ -f "$file" ] && return
    mkdir -p "$(dirname "$file")"
    ffmpeg -loglevel error -f lavfi -i "sine=frequency=$freq:duration=$secs" -ac 2 \
        -metadata artist="$artist" -metadata album_artist="$artist" -metadata album="$album" \
        -metadata title="$title" -metadata track="$track" -metadata date=2024 "$@" "$file"
}

if [ ! -d "$MUSIC" ]; then
    echo "Generating test library in $MUSIC"
    for a in "Alpha Tones:220" "Beta Waves:330"; do
        artist=${a%%:*}; base=${a##*:}
        for n in 1 2; do
            album="$artist Vol. $n"
            for t in 1 2 3; do
                freq=$((base * t + n * 50))
                if [ "$artist" = "Beta Waves" ] && [ $n = 2 ]; then
                    tone "$MUSIC/$artist/$album/0$t Tone $t.flac" $freq $((20 + t * 5)) "$artist" "$album" "Tone $t" $t -c:a flac
                else
                    tone "$MUSIC/$artist/$album/0$t Tone $t.mp3" $freq $((20 + t * 5)) "$artist" "$album" "Tone $t" $t -c:a libmp3lame -b:a 192k
                fi
            done
        done
    done
    ffmpeg -loglevel error -f lavfi -i "color=c=0x3060c0:s=300x300" -frames:v 1 "$MUSIC/Alpha Tones/Alpha Tones Vol. 1/cover.jpg"
fi

# Synced lyrics for one track (made-up words), for the lyrics window.
LRC="$MUSIC/Alpha Tones/Alpha Tones Vol. 1/01 Tone 1.lrc"
if [ -d "$(dirname "$LRC")" ] && [ ! -f "$LRC" ]; then
    cat > "$LRC" <<'LYRICS'
[00:00.50]Hagtamp test lyrics, line one
[00:04.00]A steady tone at four seconds
[00:08.00]Line three, still on pitch
[00:12.00]Halfway through the test
[00:16.00]Almost done now
[00:20.00]The last line of the tone
LYRICS
fi

mkdir -p "$ROOT/data"
echo "Starting Navidrome on port $PORT"
ND_MUSICFOLDER="$MUSIC" ND_DATAFOLDER="$ROOT/data" ND_PORT=$PORT ND_LOGLEVEL=warn \
    ND_SCANNER_SCHEDULE=0 ND_ENABLEINSIGHTSCOLLECTOR=false navidrome &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT

for _ in $(seq 1 50); do
    curl -s "http://localhost:$PORT/ping" >/dev/null 2>&1 && break
    sleep 0.2
done
# First run: create the admin user (ignored when it exists).
curl -s -X POST "http://localhost:$PORT/auth/createAdmin" -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"admin"}' >/dev/null || true
API="http://localhost:$PORT/rest"
AUTH="u=admin&p=admin&v=1.16.1&c=dev&f=json"
curl -s "$API/startScan?$AUTH" >/dev/null
for _ in $(seq 1 100); do
    if curl -s "$API/getScanStatus?$AUTH" | grep -q '"scanning":false'; then break; fi
    sleep 0.2
done
echo "Ready: $(curl -s "$API/getArtists?$AUTH" | grep -o '"name":"[^"]*"' | tr '\n' ' ')"
wait $SERVER
