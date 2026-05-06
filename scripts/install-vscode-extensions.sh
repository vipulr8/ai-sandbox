#!/usr/bin/env bash
# Bake VS Code extensions into the image at build time.
#
# Usage: install-vscode-extensions.sh <extensions-list-file>
#
# - <extensions-list-file>: text file, one publisher.extension[@version] per line.
#   Lines starting with `#` and blank lines are ignored. Build-time env vars
#   such as ${CLAUDE_VERSION} are expanded before parsing.
#
# Per-line routing:
#   - bare `publisher.ext`        -> CLI install (resolves to latest)
#   - `publisher.ext@latest`      -> CLI install (resolves to latest)
#   - `publisher.ext@X.Y.Z`       -> direct VSIX download from the marketplace
#                                    asset endpoint, then install from disk
#                                    (Microsoft's CLI does not support id@version)
#
# Why this script exists:
#   The post-attach `docker exec` install loop in dev.sh races VS Code Server's own
#   first-attach setup, swallows errors, and depends on marketplace availability at
#   container-start time. Baking extensions at build time makes the image self-contained
#   and the extension set deterministic per image tag.
#
# Where extensions land:
#   ~/.vscode-server/extensions/<publisher>.<ext>-<version>/   (the directory VS Code
#   Server reads on attach, separate from the per-commit ~/.vscode-server/bin/<sha>/
#   binary that VS Code installs itself on first attach).
#
# Multi-arch:
#   Detects target arch via `dpkg --print-architecture` and downloads the matching
#   server-linux-{x64,arm64} tarball from update.code.visualstudio.com.
set -euo pipefail

EXT_LIST="${1:?extensions list file required}"

if [ ! -f "$EXT_LIST" ]; then
    echo "Error: extension list file not found: $EXT_LIST" >&2
    exit 1
fi

# Resolve architecture
DEB_ARCH="$(dpkg --print-architecture)"
case "$DEB_ARCH" in
    amd64) VSCODE_ARCH="x64" ;;
    arm64) VSCODE_ARCH="arm64" ;;
    *) echo "Error: unsupported architecture: $DEB_ARCH" >&2; exit 1 ;;
esac

EXT_DIR="$HOME/.vscode-server/extensions"
SERVER_DIR="$(mktemp -d)"
trap 'rm -rf "$SERVER_DIR"' EXIT

mkdir -p "$EXT_DIR"

# Download Microsoft VS Code Server tarball for the build arch.
# The "latest" alias for stable always points to the most recent published commit.
echo "Downloading VS Code Server (server-linux-${VSCODE_ARCH}/stable)..."
curl -fsSL -o "$SERVER_DIR/server.tar.gz" \
    "https://update.code.visualstudio.com/latest/server-linux-${VSCODE_ARCH}/stable"

tar -xzf "$SERVER_DIR/server.tar.gz" -C "$SERVER_DIR" --strip-components=1
rm -f "$SERVER_DIR/server.tar.gz"

CLI="$SERVER_DIR/bin/code-server"
if [ ! -x "$CLI" ]; then
    echo "Error: code-server CLI not found inside extracted tarball at $CLI" >&2
    exit 1
fi

# Marketplace VSIX URL builder.
# Anthropic publishes via their own gallery host; everything else uses the
# standard VS Marketplace asset URL.
vsix_url() {
    local publisher="$1" name="$2" version="$3"
    if [ "$publisher" = "anthropic" ]; then
        printf 'https://%s.gallery.vsassets.io/_apis/public/gallery/publisher/%s/extension/%s/%s/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage' \
            "$publisher" "$publisher" "$name" "$version"
    else
        printf 'https://marketplace.visualstudio.com/_apis/public/gallery/publishers/%s/vsextensions/%s/%s/vspackage' \
            "$publisher" "$name" "$version"
    fi
}

# Process the extension list line by line.
CLI_ARGS=()        # batched CLI installs (unversioned + @latest entries)
VSIX_PATHS=()      # per-version VSIX file paths to install one-by-one
TOTAL_REQUESTED=0

while IFS= read -r raw_line; do
    # Trim whitespace
    line="$(echo "$raw_line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [ -z "$line" ] && continue
    case "$line" in
        \#*) continue ;;
    esac

    # Expand build-time env vars. Pure-bash parameter substitution (NOT eval
    # or envsubst) -- explicit allowlist of expandable vars avoids both a new
    # apt dependency (gettext-base for envsubst) and the risk of executing
    # arbitrary shell from file contents. To support a new var, add another
    # substitution line below.
    expanded="${line//\$\{CLAUDE_VERSION\}/${CLAUDE_VERSION:-latest}}"
    TOTAL_REQUESTED=$(( TOTAL_REQUESTED + 1 ))

    # Split on the first '@' (extension IDs themselves never contain '@').
    if [[ "$expanded" == *"@"* ]]; then
        ext_id="${expanded%@*}"
        ext_version="${expanded#*@}"
    else
        ext_id="$expanded"
        ext_version=""
    fi

    if [ -z "$ext_version" ] || [ "$ext_version" = "latest" ]; then
        CLI_ARGS+=( "--install-extension" "$ext_id" )
        continue
    fi

    # Versioned: download VSIX directly. Microsoft's CLI does not accept
    # id@version, so we fetch the asset and pass a file path instead.
    publisher="${ext_id%.*}"
    name="${ext_id#*.}"
    url="$(vsix_url "$publisher" "$name" "$ext_version")"
    vsix_file="$SERVER_DIR/${publisher}.${name}-${ext_version}.vsix"
    echo "Downloading ${ext_id}@${ext_version} VSIX..."
    curl -fsSL -o "$vsix_file" "$url"
    VSIX_PATHS+=( "$vsix_file" )
done < "$EXT_LIST"

if [ "$TOTAL_REQUESTED" -eq 0 ]; then
    echo "Error: extension list contains no installable entries" >&2
    exit 1
fi

# Single CLI invocation for the unversioned/@latest batch.
# Doing all CLI installs in ONE call (not one per extension) avoids the documented
# layered-build issue where each --install-extension call rewrites extensions.json
# and silently drops earlier entries (coder/code-server#7326).
if [ "${#CLI_ARGS[@]}" -gt 0 ]; then
    echo "Installing $(( ${#CLI_ARGS[@]} / 2 )) latest-version extensions via CLI..."
    "$CLI" --extensions-dir "$EXT_DIR" --user-data-dir "$SERVER_DIR/data" \
        "${CLI_ARGS[@]}"
fi

# Each pinned VSIX gets its own install call.
for vsix in "${VSIX_PATHS[@]}"; do
    echo "Installing $(basename "$vsix") from VSIX..."
    "$CLI" --extensions-dir "$EXT_DIR" --user-data-dir "$SERVER_DIR/data" \
        --install-extension "$vsix"
done

# Sanity check.
INSTALLED_COUNT="$(find "$EXT_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
if [ "$INSTALLED_COUNT" -lt "$TOTAL_REQUESTED" ]; then
    echo "Error: expected at least $TOTAL_REQUESTED extension dirs in $EXT_DIR, found $INSTALLED_COUNT" >&2
    ls -la "$EXT_DIR" >&2
    exit 1
fi

echo "Successfully installed $INSTALLED_COUNT extensions to $EXT_DIR"
ls -1 "$EXT_DIR"
