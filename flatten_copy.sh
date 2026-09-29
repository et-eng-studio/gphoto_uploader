#!/usr/bin/env bash
#
# flatten_copy.sh
#
# Recursively copies all files from a source directory into the root of a target
# directory (flattened). If duplicate file names are encountered, an index is
# appended to the file base name (preserving the file extension).
#
# Usage:
#   ./flatten_copy.sh [OPTIONS] <source_folder> <target_folder>
#
# Options:
#   --exclude <subfolder>   Exclude a subfolder by name or path (can be specified multiple times)
#   -v, --verbose           Print details for every copied file
#   -n, --dry-run           Preview actions without copying files
#   -h, --help              Show this help message
#

set -euo pipefail

usage() {
    cat << 'EOF'
Usage:
  flatten_copy.sh [OPTIONS] <source_folder> <target_folder>

Arguments:
  <source_folder>   Path to the directory containing files to copy
  <target_folder>   Path to the destination directory (files placed at root)

Options:
  --exclude <subfolder>  Exclude a subfolder by name or relative/absolute path.
                         Can be specified multiple times.
  -v, --verbose          Print details for each file copied or renamed.
  -n, --dry-run          Show what would be copied without making changes.
  -h, --help             Show this help message and exit.

Examples:
  ./flatten_copy.sh ~/Pictures ~/AllPhotos
  ./flatten_copy.sh --exclude raw --exclude thumbnails ~/Pictures ~/AllPhotos
  ./flatten_copy.sh --exclude "2020/drafts" ~/Pictures ~/AllPhotos
EOF
}

# Defaults
EXCLUDES=()
POSITIONAL=()
VERBOSE=false
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --exclude)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                echo "Error: --exclude requires a subfolder argument." >&2
                exit 1
            fi
            EXCLUDES+=("$2")
            shift 2
            ;;
        --exclude=*)
            EXCLUDES+=("${1#*=}")
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            POSITIONAL+=("$@")
            break
            ;;
        -*)
            echo "Error: Unknown option '$1'" >&2
            echo "Use -h or --help for usage information." >&2
            exit 1
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

if [[ ${#POSITIONAL[@]} -ne 2 ]]; then
    echo "Error: Exactly two positional arguments (<source_folder> and <target_folder>) are required." >&2
    echo "Use -h or --help for usage information." >&2
    exit 1
fi

SOURCE="${POSITIONAL[0]}"
TARGET="${POSITIONAL[1]}"

# Validate source directory
if [[ ! -d "$SOURCE" ]]; then
    echo "Error: Source folder '$SOURCE' does not exist or is not a directory." >&2
    exit 1
fi

# Ensure target directory exists (unless dry run)
if [[ ! -d "$TARGET" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
        echo "[Dry-run] Would create target folder: $TARGET"
    else
        mkdir -p "$TARGET" || {
            echo "Error: Failed to create target folder '$TARGET'." >&2
            exit 1
        }
    fi
fi

# Canonicalize paths
SRC_REAL=$(realpath "$SOURCE")
TGT_REAL=$(realpath -m "$TARGET")

if [[ "$SRC_REAL" == "$TGT_REAL" ]]; then
    echo "Error: Source and target folders cannot be the same directory ('$SRC_REAL')." >&2
    exit 1
fi

# If target is inside source, automatically exclude target directory to avoid recursion loops
if [[ "$TGT_REAL" == "$SRC_REAL"/* ]]; then
    EXCLUDES+=("$TGT_REAL")
fi

# Split filename into base and extension
# Examples:
#   photo.jpg         -> base: photo,        ext: .jpg
#   archive.tar.gz    -> base: archive.tar,  ext: .gz
#   Makefile          -> base: Makefile,     ext: ""
#   .gitignore        -> base: .gitignore,   ext: ""
#   .config.json      -> base: .config,      ext: .json
split_filename() {
    local fname="$1"
    if [[ "$fname" == *.* ]]; then
        local without_leading_dot="${fname#.}"
        if [[ "$without_leading_dot" == *.* ]]; then
            file_ext=".${fname##*.}"
            file_base="${fname%.*}"
        elif [[ "$fname" == .* ]]; then
            file_ext=""
            file_base="$fname"
        else
            file_ext=".${fname##*.}"
            file_base="${fname%.*}"
        fi
    else
        file_ext=""
        file_base="$fname"
    fi
}

# Build find prune expression
prune_clause=()
for item in "${EXCLUDES[@]}"; do
    clean="${item%/}"
    while [[ "$clean" == ./* ]]; do
        clean="${clean#./}"
    done
    [[ -z "$clean" ]] && continue

    item_subclause=()
    if [[ "$clean" == /* ]]; then
        item_subclause=(-path "$clean")
    elif [[ "$clean" != */* ]]; then
        item_subclause=(-name "$clean" -o -path "$SRC_REAL/$clean")
    else
        item_subclause=(-path "$SRC_REAL/$clean" -o -path "*/$clean")
    fi

    if [[ ${#prune_clause[@]} -gt 0 ]]; then
        prune_clause+=(-o)
    fi
    prune_clause+=("${item_subclause[@]}")
done

if [[ ${#prune_clause[@]} -gt 0 ]]; then
    full_prune=(\( "${prune_clause[@]}" \) -prune -o)
else
    full_prune=()
fi

# Track allocations to prevent collisions even in dry-run or when processing multiple duplicates
declare -A allocated_dests
declare -A name_counters

resolve_destination() {
    local fname="$1"
    split_filename "$fname"

    local dest="$TARGET/$fname"
    # If the target file already exists or was already allocated for another file:
    if [[ -e "$dest" || -L "$dest" || -n "${allocated_dests["$dest"]:-}" ]]; then
        local idx=1
        if [[ -n "${name_counters["$fname"]:-}" ]]; then
            idx="${name_counters["$fname"]}"
        fi
        while true; do
            dest="$TARGET/${file_base}_${idx}${file_ext}"
            if [[ ! -e "$dest" && ! -L "$dest" && -z "${allocated_dests["$dest"]:-}" ]]; then
                break
            fi
            idx=$((idx + 1))
        done
        name_counters["$fname"]=$((idx + 1))
        is_collision=true
    else
        is_collision=false
    fi

    allocated_dests["$dest"]=1
    resolved_dest="$dest"
}

total_files=0
copied_files=0
collision_files=0

echo "Starting flattened copy from '$SOURCE' to '$TARGET'..."
if [[ ${#EXCLUDES[@]} -gt 0 ]]; then
    echo "Excluded pattern(s): ${EXCLUDES[*]}"
fi
if [[ "$DRY_RUN" == true ]]; then
    echo "[Mode: Dry run - no files will actually be copied]"
fi

# Find files and process deterministically with sort
while IFS= read -r -d '' src_file; do
    # Only copy regular files or symlinks pointing to regular files
    if [[ ! -f "$src_file" ]]; then
        continue
    fi

    fname=$(basename "$src_file")
    resolve_destination "$fname"

    total_files=$((total_files + 1))

    if [[ "$is_collision" == true ]]; then
        collision_files=$((collision_files + 1))
        dest_name=$(basename "$resolved_dest")
        if [[ "$VERBOSE" == true || "$DRY_RUN" == true ]]; then
            echo "[Renamed] '$src_file' -> '$dest_name' (collision with '$fname')"
        fi
    else
        if [[ "$VERBOSE" == true || "$DRY_RUN" == true ]]; then
            echo "[Copied]  '$src_file' -> '$fname'"
        fi
    fi

    if [[ "$DRY_RUN" == false ]]; then
        # Preserve timestamps and permissions (-p), dereference symlinks (-L)
        cp -p -L "$src_file" "$resolved_dest"
        copied_files=$((copied_files + 1))
    else
        copied_files=$((copied_files + 1))
    fi

    if (( copied_files % 100 == 0 )); then
        if [[ "$DRY_RUN" == true ]]; then
            echo "Progress: $copied_files files processed ($collision_files renamed)..."
        else
            echo "Progress: $copied_files files copied ($collision_files renamed)..."
        fi
    fi
done < <(find "$SRC_REAL" "${full_prune[@]}" \( -type f -o -type l \) -print0 | sort -z)

echo "----------------------------------------"
if [[ "$DRY_RUN" == true ]]; then
    echo "Dry run complete."
    echo "Total files that would be copied: $copied_files"
    echo "Files with renamed collisions:   $collision_files"
else
    echo "Copy complete."
    echo "Total files copied:              $copied_files"
    echo "Files with renamed collisions:   $collision_files"
fi
