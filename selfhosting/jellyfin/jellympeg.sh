#!/usr/bin/env bash
# =============================================================================
# jellympeg.sh — Unified video encoder with modular flag assembly
#
# Usage:
#   jellympeg.sh [OPTIONS] [FILE...]
#   (no FILE = scan current directory)
#
# Options:
#   --deint          Force deinterlace on all files
#   --codec <name>   Force encoder: av1 | hevc | h264  (default: auto/av1)
#   --4k-bitrate <k> Override 4K target bitrate in kbps (default: 6000)
#   --hd-bitrate <k> Override HD target bitrate in kbps (default: 4000)
#   --dry-run        Print ffmpeg commands without executing them
#   --help           Show this help
#
# Codec selection order (per vendor):
#   Intel  → av1_qsv  / hevc_qsv  / h264_qsv
#   Nvidia → av1_nvenc / hevc_nvenc / h264_nvenc
#   AMD    → av1_amf  / hevc_amf  / h264_amf
#   SW     → libx264  (H264 only, always available as last resort)
#
# Bitrate scaling vs AV1 baseline:
#   HEVC  → ×1.20  (same quality needs ~20% more bits)
#   H264  → ×1.40  (same quality needs ~40% more bits)
# =============================================================================
set -euo pipefail
# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
OPT_FORCE_DEINT=false
OPT_CODEC_FAMILY=""          # av1 | hevc | h264 | "" (auto → prefer av1)
OPT_4K_BASE=6000             # kbps, AV1 baseline
OPT_HD_BASE=4000             # kbps, AV1 baseline
OPT_DRY_RUN=false
EXPLICIT_FILES=()

VIDEO_EXTENSIONS=("mkv" "mp4" "mov" "ts" "avi" "m2ts")
# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --deint)        OPT_FORCE_DEINT=true ; shift ;;
        --codec)        OPT_CODEC_FAMILY="${2,,}" ; shift 2 ;;
        --4k-bitrate)   OPT_4K_BASE="$2" ; shift 2 ;;
        --hd-bitrate)   OPT_HD_BASE="$2" ; shift 2 ;;
        --dry-run)      OPT_DRY_RUN=true ; shift ;;
        --help)
            sed -n '2,/^# ====*/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --) shift ; EXPLICIT_FILES+=("$@") ; break ;;
        -*) echo "Unknown option: $1" >&2 ; exit 1 ;;
        *)  EXPLICIT_FILES+=("$1") ; shift ;;
    esac
done
# ---------------------------------------------------------------------------
# MODULE: Encoder detection
#
# Sets globals:
#   ENCODER      — ffmpeg encoder name (e.g. av1_qsv)
#   CODEC_FAMILY — av1 | hevc | h264
#   HW_VENDOR    — intel | nvidia | amd | software
# ---------------------------------------------------------------------------
_intel_xe_available() {
    local pci_id
    while IFS= read -r pci_id; do
        local driver_path="/sys/bus/pci/devices/${pci_id}/driver"
        if [[ -L "$driver_path" ]]; then
            local driver_name
            driver_name=$(basename "$(readlink -f "$driver_path")")
            [[ "$driver_name" == "xe" ]] && return 0
        fi
    done < <(lspci -D 2>/dev/null \
        | awk '/VGA|3D|Display/ && /Intel/ {print $1}')
    return 1
}
detect_encoder() {
    local want_family="${1:-av1}"
    local candidates=(
        "av1_qsv    av1  intel"
        "hevc_qsv   hevc intel"
        "h264_qsv   h264 intel"
        "av1_nvenc  av1  nvidia"
        "hevc_nvenc hevc nvidia"
        "h264_nvenc h264 nvidia"
        "av1_amf    av1  amd"
        "hevc_amf   hevc amd"
        "h264_amf   h264 amd"
        "libx264    h264 software"
    )
    local intel_ok=false # check if intel GPU is viable for QSV encoding
    _intel_xe_available && intel_ok=true
    $intel_ok || echo "Note: Intel QSV skipped (xe driver not detected)." >&2
    local filtered=()
    for entry in "${candidates[@]}"; do
        local enc fam ven
        read -r enc fam ven <<< "$entry"
        if [[ -z "$want_family" || "$fam" == "$want_family" ]]; then
            filtered+=("$entry")
        fi
    done
    if [[ "$want_family" != "h264" && "$want_family" != "" ]]; then
        filtered+=("libx264 h264 software")
    fi

    for entry in "${filtered[@]}"; do
        local enc fam ven
        read -r enc fam ven <<< "$entry"
        if ffmpeg -hide_banner -loglevel quiet \
                -f lavfi -i nullsrc=s=64x64:r=1:d=1 \
                -frames:v 1 -c:v "$enc" -f null - 2>/dev/null; then
            ENCODER="$enc"
            CODEC_FAMILY="$fam"
            HW_VENDOR="$ven"
            return 0
        fi
    done
    echo "ERROR: No suitable encoder found for family '${want_family:-any}'." >&2
    exit 1
}
# ---------------------------------------------------------------------------
# MODULE: Bitrate assembly
#
# Args:   $1 = is_4k (true|false)
# Reads:  CODEC_FAMILY, OPT_4K_BASE, OPT_HD_BASE
# Sets:   BR_TARGET BR_MAX BR_BUF  (all in kbps, as integers)
# ---------------------------------------------------------------------------
assemble_bitrate() {
    local is_4k="$1"

    local base
    $is_4k && base=$OPT_4K_BASE || base=$OPT_HD_BASE
    local scale=100
    case "$CODEC_FAMILY" in
        hevc) scale=120 ;;
        h264) scale=140 ;;
    esac

    BR_TARGET=$(( base * scale / 100 ))
    BR_MAX=$(( BR_TARGET * 14 / 10 ))
    BR_BUF=$BR_MAX
}
# ---------------------------------------------------------------------------
# MODULE: Codec-specific encoder flags
#
# Reads:  ENCODER, HW_VENDOR, CODEC_FAMILY
# Sets:   ENC_FLAGS (array)
# ---------------------------------------------------------------------------
assemble_enc_flags() {
    ENC_FLAGS=()

    case "$HW_VENDOR" in
        intel)
            ENC_FLAGS+=(
                -preset veryslow
                -look_ahead_depth 8
                -async_depth 1
                -adaptive_i 1
                -adaptive_b 1
                -extbrc 1
            )
            ;;
        nvidia)
            ENC_FLAGS+=(
                -preset p7
                -tune hq
                -multipass fullres
                -spatial_aq 1
                -temporal_aq 1
                -rc-lookahead:v 32
            )
            ;;
        amd)
            ENC_FLAGS+=(
                -quality quality
                -rc_mode vbr_latency
                -enforce_hrd 1
            )
            ;;
        software)
            ENC_FLAGS+=(
                -preset slow
                -tune film
            )
            ;;
    esac
}
# ---------------------------------------------------------------------------
# MODULE: Video filter chain assembly
#
# Args:   $1 = is_hdr (true|false)
#         $2 = is_interlaced (true|false)
# Sets:   VF_CHAIN (string)
# ---------------------------------------------------------------------------
assemble_vf() {
    local is_hdr="$1"
    local is_interlaced="$2"
    local parts=()

    if $is_interlaced; then
        parts+=("bwdif=mode=send_field:parity=auto:deint=interlaced")
    fi
    if $is_hdr; then
        parts+=(
            "zscale=tin=smpte2084:min=bt2020nc:pin=bt2020:rin=tv:t=smpte2084:m=bt2020nc:p=bt2020:r=tv"
            "zscale=t=linear"
            "format=gbrpf32le"
            "zscale=p=bt709"
            "tonemap=tonemap=reinhard:desat=0"
            "zscale=t=bt709:m=bt709:r=tv"
        )
    fi
    parts+=("format=yuv420p")

    local IFS=','
    VF_CHAIN="${parts[*]}"
}
# ---------------------------------------------------------------------------
# Colour metadata flags (only meaningful after SDR conversion)
# ---------------------------------------------------------------------------
assemble_color_flags() {
    local is_hdr="$1"
    COLOR_FLAGS=()
    if $is_hdr; then
        COLOR_FLAGS+=(
            -color_range 1
            -colorspace 1
            -color_primaries bt709
            -color_trc bt709
        )
    fi
}
# ---------------------------------------------------------------------------
# Probe helpers
# ---------------------------------------------------------------------------
is_video_file() {
    local ext="${1##*.}"
    ext="${ext,,}"
    for e in "${VIDEO_EXTENSIONS[@]}"; do
        [[ "$e" == "$ext" ]] && return 0
    done
    return 1
}

probe_stream() {
    ffprobe -v error -select_streams v:0 \
        -show_entries "stream=$2" -of default=nw=1:nk=1 "$1" 2>/dev/null
}

detect_hdr() {
    [[ "$(probe_stream "$1" color_transfer)" == "smpte2084" ]]
}

detect_4k() {
    local w
    w=$(probe_stream "$1" width)
    [[ -n "$w" && "$w" -ge 3840 ]]
}

detect_interlaced() {
    local fo
    fo=$(probe_stream "$1" field_order)
    case "$fo" in tt|bb|tb|bt) return 0 ;; *) return 1 ;; esac
}
# ---------------------------------------------------------------------------
# Encode one file
# ---------------------------------------------------------------------------
encode_file() {
    local input="$1"
    echo "──────────────────────────────────────────"
    echo "File     : $input"
    local is_hdr=false is_4k=false is_interlaced=false
    detect_hdr        "$input" && is_hdr=true
    detect_4k         "$input" && is_4k=true
    detect_interlaced "$input" && is_interlaced=true
    $OPT_FORCE_DEINT  && is_interlaced=true
    local hdr_label res_label int_label
    $is_hdr        && hdr_label="HDR10" || hdr_label="SDR"
    $is_4k         && res_label="4K"    || res_label="HD"
    $is_interlaced && int_label="Interlaced" || int_label="Progressive"
    echo "Detected : $hdr_label | $res_label | $int_label"
    assemble_bitrate   "$is_4k"
    assemble_enc_flags
    assemble_vf        "$is_hdr" "$is_interlaced"
    assemble_color_flags "$is_hdr"
    local output="${input%.*}_encoded.mkv"
    echo "Encoder  : $ENCODER ($HW_VENDOR)"
    echo "Bitrate  : ${BR_TARGET}k target / ${BR_MAX}k max"
    local cmd=(
        ffmpeg -i "$input"
        -vf "$VF_CHAIN"
        "${COLOR_FLAGS[@]}"
        -c:v "$ENCODER"
        -b:v "${BR_TARGET}k"
        -maxrate "${BR_MAX}k"
        -bufsize "${BR_BUF}k"
        -rc vbr
        "${ENC_FLAGS[@]}"
        -map 0:v:0 -map "0:a?" -map "0:s?"
        -c:a copy -c:s copy
        "$output"
    )
    if [[ "$HW_VENDOR" == "software" ]]; then
        cmd=(
            ffmpeg -i "$input"
            -vf "$VF_CHAIN"
            "${COLOR_FLAGS[@]}"
            -c:v "$ENCODER"
            -b:v "${BR_TARGET}k"
            -maxrate "${BR_MAX}k"
            -bufsize "${BR_BUF}k"
            "${ENC_FLAGS[@]}"
            -map 0:v:0 -map "0:a?" -map "0:s?"
            -c:a copy -c:s copy
            "$output"
        )
    fi

    echo "Output   : $output"
    if $OPT_DRY_RUN; then
        echo "Command  : ${cmd[*]}"
        echo "[dry-run] Skipping execution."
    else
        "${cmd[@]}"
        echo "Done     : $output"
    fi
}
# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    detect_encoder "$OPT_CODEC_FAMILY"
    echo "Encoder selected: $ENCODER ($HW_VENDOR, family=$CODEC_FAMILY)"
    echo ""

    local found=0
    if [[ ${#EXPLICIT_FILES[@]} -gt 0 ]]; then
        for f in "${EXPLICIT_FILES[@]}"; do
            is_video_file "$f" || { echo "Skipping non-video: $f"; continue; }
            encode_file "$f"
            (( found++ )) || true
        done
    else
        for f in *; do
            is_video_file "$f" || continue
            encode_file "$f"
            (( found++ )) || true
        done
    fi

    [[ $found -eq 0 ]] && echo "No video files found."
}
main
