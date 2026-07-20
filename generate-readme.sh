#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
README="$SCRIPT_DIR/README.md"
COLUMNS=6
THUMBNAIL_WIDTH=320

EXTS="png|jpg|jpeg|webp|gif|bmp"

# ── 1. Detect package manager ──────────────────────────────────────────────
detect_pkg_manager() {
    if command -v pacman &>/dev/null; then  echo "pacman"
    elif command -v apt &>/dev/null; then   echo "apt"
    elif command -v dnf &>/dev/null; then   echo "dnf"
    elif command -v zypper &>/dev/null; then echo "zypper"
    elif command -v apk &>/dev/null; then   echo "apk"
    elif command -v brew &>/dev/null; then  echo "brew"
    else echo "unknown"; fi
}

# ── 2. Install ImageMagick if missing ──────────────────────────────────────
ensure_imagemagick() {
    if command -v magick &>/dev/null; then
        return
    fi
    if command -v convert &>/dev/null; then
        # ImageMagick v6 — alias 'convert' as 'magick' for our usage
        IM_IS_V6=1
        return
    fi

    local pm
    pm=$(detect_pkg_manager)
    echo "→ ImageMagick not found. Installing via $pm..."

    case "$pm" in
        pacman) sudo pacman -S --noconfirm imagemagick ;;
        apt)    sudo apt update -qq && sudo apt install -y imagemagick ;;
        dnf)    sudo dnf install -y ImageMagick ;;
        zypper) sudo zypper install -y ImageMagick ;;
        apk)    sudo apk add imagemagick ;;
        brew)   brew install imagemagick ;;
        *)
            echo "✗ Unknown package manager. Install ImageMagick manually:"
            echo "  https://imagemagick.org/script/download.php"
            exit 1
            ;;
    esac
    echo "✓ ImageMagick installed"
}

# ── 3. Gather images ───────────────────────────────────────────────────────
gather_images() {
    find "$SCRIPT_DIR" -maxdepth 1 -type f \
        -regextype posix-extended -regex ".*\.(${EXTS})$" \
        -printf '%f\0' | sort -z
}

# ── 4. Extract average HSL color ───────────────────────────────────────────
# Returns "hue lightness saturation" (0-1 scale)
average_hsl() {
    local img="$1"
    local cmd="magick"
    if [[ "${IM_IS_V6:-0}" -eq 1 ]]; then
        cmd="convert"
    fi
    local line
    line=$("$cmd" "$SCRIPT_DIR/$img" -resize 1x1 -colorspace HSL txt:- 2>/dev/null | grep "^0,0:")
    # Output: 0,0: (45847,23130,38550)  #B31A5A96  hsl(70.7141%,35.3009%,58.8328%)
    # Extract the hsl(...) part
    local hsl
    hsl=$(echo "$line" | grep -oP 'hsl\([^)]+\)' | head -1)
    if [[ -z "$hsl" ]]; then
        # Fallback: parse the raw values
        # ImageMagick HSL: H=0-65535, S=0-65535, L=0-65535 for Q16
        local raw
        raw=$(echo "$line" | grep -oP '\(\d+,\d+,\d+\)' | head -1)
        raw="${raw#(}"; raw="${raw%)}"
        IFS=',' read -r h s l <<< "$raw"
        # Normalize to 0-1
        awk -v h="$h" -v s="$s" -v l="$l" 'BEGIN { printf "%.4f %.4f %.4f", h/65535, s/65535, l/65535 }'
    else
        # Parse hsl(70.7141%,35.3009%,58.8328%)
        hsl="${hsl#hsl(}"; hsl="${hsl%)}"
        IFS=',' read -r h s l <<< "$hsl"
        h="${h%\%}"; s="${s%\%}"; l="${l%\%}"
        awk -v h="$h" -v s="$s" -v l="$l" 'BEGIN { printf "%.4f %.4f %.4f", h/100, s/100, l/100 }'
    fi
}

# ── 5. Compute stats ───────────────────────────────────────────────────────
compute_stats() {
    local images=("$@")
    local count=${#images[@]}
    local total_bytes=0
    declare -A fmt_count

    for img in "${images[@]}"; do
        local ext="${img##*.}"
        ext="${ext,,}"
        fmt_count["$ext"]=$((${fmt_count["$ext"]:-0} + 1))
        local size
        size=$(stat -c%s "$SCRIPT_DIR/$img" 2>/dev/null || echo 0)
        total_bytes=$((total_bytes + size))
    done

    # Human-readable size
    local total_human
    if command -v numfmt &>/dev/null; then
        total_human=$(numfmt --to=iec --suffix=B "$total_bytes")
    else
        total_human=$(awk -v b="$total_bytes" 'BEGIN {
            if (b>=1073741824) printf "%.1f GB", b/1073741824
            else if (b>=1048576) printf "%.1f MB", b/1048576
            else if (b>=1024) printf "%.1f KB", b/1024
            else printf "%d B", b
        }')
    fi

    # Format breakdown sorted by count desc
    local sorted_fmts
    sorted_fmts=$(for ext in "${!fmt_count[@]}"; do
        printf '%d %s\n' "${fmt_count[$ext]}" "$ext"
    done | sort -rn | awk '{printf "%s ×%s  ", toupper($2), $1}')

    echo "$count|$total_human|$sorted_fmts"
}

# ── 6. Generate README ─────────────────────────────────────────────────────
generate_readme() {
    local count="$1" total_human="$2" fmt_list="$3"
    shift 3
    local images=("$@")

    local tmp="$README.tmp"
    {
        # Header
        printf "<div align='center'>\n\n"
        printf "# 🖼️  Wallpapers\n\n"
        printf "**%s wallpapers**  ·  💾 %s  ·  📐 %s\n" \
            "$count" "$total_human" "$fmt_list"
        printf "\n</div>\n\n"
        printf '%s\n\n' '---'
        printf "<div align='center'>\n\n"
        printf "<table><tr>\n"

        # Image grid
        local i=0
        for img in "${images[@]}"; do
            if ((i > 0 && i % COLUMNS == 0)); then
                printf "</tr><tr>\n"
            fi
            local stem="${img%.*}"
            printf '<td align="center"><a href="%s"><img src="%s" width="%d" alt="%s" title="%s" loading="lazy"/></a></td>\n' \
                "$img" "$img" "$THUMBNAIL_WIDTH" "$stem" "$stem"
            ((i++)) || true
        done

        # Fill remaining cells
        local rem=$(( (COLUMNS - (i % COLUMNS)) % COLUMNS ))
        for ((j = 0; j < rem; j++)); do
            printf "<td></td>\n"
        done

        printf "</tr></table>\n\n"
        printf "</div>\n"
    } > "$tmp"

    mv "$tmp" "$README"
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    IM_IS_V6=0
    ensure_imagemagick

    echo "→ Gathering images..."
    mapfile -d '' images < <(gather_images)
    echo "  Found ${#images[@]} images"

    echo "→ Computing stats..."
    IFS='|' read -r count total_human fmt_list < <(compute_stats "${images[@]}")
    echo "  $count wallpapers · $total_human"

    echo "→ Extracting colors (this may take a moment)..."
    # Build sortable lines: hue:lightness:saturation:filename
    local colored_lines=()
    local idx=0
    for img in "${images[@]}"; do
        local hsl
        hsl=$(average_hsl "$img" 2>/dev/null || echo "0 0 0")
        read -r h l s <<< "$hsl"
        # Round hue for grouping, keep lightness for secondary sort
        printf -v key '%s\t%s\t%s\t%s' "$h" "$l" "$s" "$img"
        colored_lines+=("$key")
        ((idx++)) || true
        # Progress every 10
        if ((idx % 10 == 0)); then
            echo "  $idx/${#images[@]}..."
        fi
    done

    echo "→ Sorting by color..."
    # Sort by hue (field 1), then lightness (field 2)
    mapfile -t sorted_images < <(
        printf '%s\n' "${colored_lines[@]}" \
        | sort -t$'\t' -k1,1n -k2,2n \
        | awk -F'\t' '{print $4}'
    )

    echo "→ Generating $README..."
    generate_readme "$count" "$total_human" "$fmt_list" "${sorted_images[@]}"

    echo "✓ Done — $README"
}

main
