#!/bin/sh

REGISTRY_URL=https://registry-1.docker.io

if [ -n "$NOCKER_ROOT" ]; then
    NOCKER_ROOT="$NOCKER_ROOT"
elif [ "$(id -u)" -eq 0 ]; then
    NOCKER_ROOT="/var/lib/nocker"
else
    NOCKER_ROOT="$HOME/.local/share/nocker"
fi
GLOBAL_LAYERS_DIR="$NOCKER_ROOT/global_layers"
REL_GLOBAL_LAYERS_DIR="../../../../../global_layers"

SCRIPT_DIR="$(dirname "$0")"
LIB_PATH=$(realpath "$SCRIPT_DIR/nk-lib.sh")
LOG_FILE="$NOCKER_ROOT/$SCRIPT_NAME.log"

IMAGES_DIR="$NOCKER_ROOT/images"
CONTAINERS_DIR="$NOCKER_ROOT/containers"

USE_OVERLAYFS=$( [ "$(id -u)" -eq 0 ] && grep -q overlay /proc/filesystems && echo 1 || echo 0 )

shell_quote() {
  if [ -z "$1" ]; then
    printf "''"
  else
    printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
  fi
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" >&2
}

time_ago() {
    timestamp="$1"
    now=$(date +%s)
    past=$(date -d "$timestamp" +%s)
    diff=$((now - past))
    
    if [ $diff -lt 60 ]; then
        echo "${diff} seconds ago"
    elif [ $diff -lt 3600 ]; then
        echo "$((diff/60)) minutes ago"
    elif [ $diff -lt 86400 ]; then
        echo "$((diff/3600)) hours ago"
    else
        echo "$((diff/86400)) days ago"
    fi
}

http_get() {
    URL="$1"
    OUTPUT="$2"
    shift 2
    
    if command -v curl >/dev/null 2>&1; then
        CMD="curl -f -sSL"
        for arg in "$@"; do
            CMD="$CMD -H \"$arg\""
        done
        CMD="$CMD \"$URL\" -o \"$OUTPUT\""
        eval "$CMD" || return 1
    elif command -v wget >/dev/null 2>&1; then
        CMD="wget"
        for arg in "$@"; do
            CMD="$CMD --header=\"$arg\""
        done
        CMD="$CMD -qO \"$OUTPUT\" \"$URL\""
        eval "$CMD" || return 1
    else
        error "Ни curl, ни wget не найдены."
        return 1
    fi
}

http_get_auth() {
    http_get "$1" "$2" "Authorization: Bearer $TOKEN" "$@"
}

parse_image_input() {
    case "$1" in
        *:*)
            REPO=$(echo "$1" | cut -d':' -f1)
            TAG=$(echo "$1" | cut -d':' -f2)
            ;;
        *)
            REPO="$1"
            TAG="latest"
            ;;
    esac

    case "$REPO" in
        */*)
            REPO_FULL="$REPO"
            ;;
        *)
            REPO_FULL="library/$REPO"
            ;;
    esac
}

kill_wait() {
    pid=$1
    timeout=$2

    kill "$pid"
    while [ $timeout -gt 0 ]; do
        if kill -0 "$pid" 2>/dev/null; then
            sleep 1
            timeout=$((timeout - 1))
        else
            return 0
        fi
    done

    return 1
}

kill_wait_group() {
    pgid=$1
    timeout=$2

    kill -- -$pgid || return 0
    while [ $timeout -gt 0 ]; do
        if ps -o pgid | grep -q -w $pgid; then
            sleep 1
            timeout=$((timeout - 1))
        else
            return 0
        fi
    done

    return 1
}

prompt_confirmation() {
    prompt="${1:-Are you sure you want to continue?}"
    printf "%s [y/N] " "$prompt" >&2
    read -r answer
    case "$answer" in
        [yY]) return 0;;
        *)     return 1;;
    esac
}

parse_image_config() {
    parse_image_input "$1"
    user_cmd="$2"
    
    config_file="$IMAGES_DIR/$REPO_FULL/$TAG/config.json"
    if [ ! -f "$config_file" ]; then
        log "Error: config.json not found for image $image"
        exit 1
    fi

    config_cmd=$(jq -r '.config.Cmd // [] | map("\"\(.)\"") | join(" ")' "$config_file")
    config_entrypoint=$(jq -r '.config.Entrypoint // [] | join(" ")' "$config_file")
    config_env=$(jq -r '.config.Env // [] | join("\n")' "$config_file")
    config_workdir=$(jq -r '.config.WorkingDir // ""' "$config_file")
    config_user=$(jq -r '.config.User // "root"' "$config_file")

    env_vars=""
    if [ -n "$config_env" ]; then
        while IFS= read -r line; do
            env_vars="$env_vars $line"
        done <<EOF
$config_env
EOF
    fi

    if [ -n "$user_cmd" ]; then
        final_cmd="$user_cmd"
    elif [ -n "$config_entrypoint" ]; then
        final_cmd="$config_entrypoint $config_cmd"
    else
        final_cmd="$config_cmd"
    fi

    #final_cmd=$(echo "$final_cmd" | sed "s/['\"]//g")
    echo "${env_vars# }|$config_workdir|$config_user|$final_cmd"
}

set_lower_dirs_for_image() {
    layers_dir="$1"

    lower_dirs=""
    for layer in $(ls -1v "$layers_dir" 2>/dev/null); do
        layer_path="$layers_dir/$layer"
        [ -d "$layer_path" ] || continue
        lower_dirs="$layer_path:$lower_dirs"
    done
    lower_dirs="${lower_dirs%:}"
}

mount_image_layers_overlay() {
    container_dir="$1"
    layers_dir="$2"

    set_lower_dirs_for_image "$layers_dir"

    if [ -z "$lower_dirs" ]; then
        return
    fi

    mkdir -p "$container_dir/merged" "$container_dir/upper" "$container_dir/work"
    mount -t overlay overlay \
        -o "lowerdir=$lower_dirs,upperdir=$container_dir/upper,workdir=$container_dir/work" \
        "$container_dir/merged" 2>/dev/null
}

mount_image_layers_vfs() {
    container_dir="$1"
    layers_dir="$2"

    set_lower_dirs_for_image "$layers_dir"

    if [ -z "$lower_dirs" ]; then
        return
    fi

    log "WARNING: Using slow copy method instead of overlayfs"
    merged_dir="$container_dir/merged"
    mkdir -p "$merged_dir"
    echo "$lower_dirs" | tr ':' '\n' | tac | while read -r layer; do
        cp -af "$layer/." "$merged_dir"
    done
}

mount_image_layers() {
    parse_image_input "$1"
    container_dir=$2

    layers_dir="$IMAGES_DIR/$REPO_FULL/$TAG/layers"
    lower_dirs=""
    
    set_lower_dirs_for_image "$layers_dir"

    if [ -z "$lower_dirs" ]; then
        log "Error: No layers found for image $image"
        exit 1
    fi

    if [ "$USE_OVERLAYFS" -eq 1 ]; then
        mount_image_layers_overlay "$container_dir" "$layers_dir"
    else
        mount_image_layers_vfs "$container_dir" "$layers_dir"
    fi
}

generate_container_id() {
    date +%s%N | sha1sum | cut -d " " -f1
}

save_metadata() {
    container_dir=$1
    container_id=$2
    image=$3
    final_cmd=$4
    workdir=$5
    env_vars=$6
    user=$7
    restart_policy=$8
    attach_session=$9
    volumes=${10}
    ports=${11}

    meta="$container_dir/metadata.json"
    mkdir -p "$(dirname "$meta")"
    cat <<EOF > "$meta"
{
    "id": "$container_id",
    "image": "$image",
    "command": "$(echo "$final_cmd" | sed 's/"/\\"/g')",
    "workdir": "$(echo "$workdir" | sed 's/"/\\"/g')",
    "env": ["$(echo "$env_vars" | sed 's/ /","/g')"],
    "user": "$(echo "$user" | sed 's/"/\\"/g')",
    "restart_policy": "$restart_policy",
    "created": "$(date +%Y-%m-%dT%H:%M:%S)",
    "exited_at": "never",
    "exit_code": -1,
    "status": "running",
    "pid": "$$",
    "attach_session": "$attach_session",
    "volumes": "$volumes",
    "ports": "$ports"
}
EOF
    #cat "$meta"
}

run_in_container() {
    container_id=$1
    workdir=$2
    env_vars=$3
    user=$4
    interactive=$5
    tty_flag=$6
    volumes=$7
    ports=$8
    is_main_process=$9
    shift 9
    merged_dir="$CONTAINERS_DIR/$container_id/merged"
    command="$*"

    mkdir -p /tmp/nocker_$container_id /run/shm/nocker_$container_id

    (
        # unexport all host variables
        unset IFS
        for var in $(env | cut -d'=' -f1); do
            eval "value=\"\$$var\""
            eval "$var=\"\$value\""
            unset -v "$var"
        done

        for var in $env_vars; do
            #log export "${var?}"
            export "${var?}"
        done

        if [ "$USE_OVERLAYFS" -eq 1 ]; then
            if [ -n "$volumes" ]; then
                for vol in $volumes; do
                    host_path=$(echo "$vol" | cut -d: -f1)
                    container_path=$(echo "$vol" | cut -d: -f2)
                    mount --bind "$host_path" "$merged_dir$container_path"
                done
            fi

            if [ -x "$merged_dir/bin/sh" ]; then
                CMD="chroot \"$merged_dir\" /bin/sh -c \"cd ${workdir:-/} && exec $command\""
            else
                CMD="chroot \"$merged_dir\" $command"
            fi
        else
            proot_cmd="proot -0 -r \"$merged_dir\" -b /tmp/nocker_$container_id:/tmp -b /run/shm/nocker_$container_id:/run/shm -b /proc -b /sys -b /dev --kill-on-exit -w \"${workdir:-/}\""
            for vol in $volumes; do
                proot_cmd="$proot_cmd -b $vol"
            done

            for port in $ports; do
                if [ "${port#*:}" != "$port" ]; then
                    host_port=${port%:*}
                    container_port=${port#*:}
                    proot_cmd="$proot_cmd -p ${container_port}:${host_port}"
                else
                    proot_cmd="$proot_cmd -p $port"
                fi
            done

            CMD="$proot_cmd $command"
        fi
        CMD="exec $CMD"

        meta="$CONTAINERS_DIR/$container_id/metadata.json"
        if [ "$is_main_process" = "true" ]; then
            CMD="jq --arg pid \"\$\$\" '.pid = (\$pid|tonumber) | .status = \"running\"' \"$meta\" > tmp && mv tmp \"$meta\"; $CMD"
        fi

        #log "$CMD"

        if [ "$interactive" -eq 0 ]; then
            setsid sh -c "$CMD" < /dev/null
        else
            setsid sh -c "$CMD"
        fi
        exit_code=$?

        if [ "$is_main_process" = "true" ]; then
            exited_at=$(date -u +"%Y-%m-%dT%H:%M:%S")
            jq --arg exited_at "$exited_at" --arg code "$exit_code" '.status = "exited" | .exited_at = $exited_at | .exit_code = $code' "$meta" > tmp && mv tmp "$meta"
        fi

        # Если тома монтировались через mount --bind, отмонтируем их
        if [ "$USE_OVERLAYFS" -eq 1 ] && [ -n "$volumes" ]; then
            for vol in $volumes; do
                container_path=$(echo "$vol" | cut -d: -f2)
                umount "$merged_dir$container_path"
            done
        fi
        return $exit_code
    )
    return $?
}

cleanup_container() {
    container_dir=$1
    merged_dir=$2

    meta="$container_dir/metadata.json"
    if [ "$USE_OVERLAYFS" -eq 1 ]; then
        umount "$merged_dir"
        rm -rf "$container_dir/upper"
    fi
}

find_container() {
    prefix=$1
    matches=$(find "$CONTAINERS_DIR/$prefix"* -maxdepth 1 -name metadata.json 2>/dev/null)
    
    if [ -z "$matches" ]; then
        echo "Error: No such container: $prefix" >&2
        return 1
    elif [ "$(echo "$matches" | wc -l)" -gt 1 ]; then
        echo "Error: multiple IDs found with provided prefix: '$prefix':" >&2
        for file in $matches; do basename "$(dirname "$file")"; done | sed 's/^/  /' >&2
        return 2
    fi
    basename "$(dirname "$matches")"
}

nk_pull() {
    error() {
        echo "Error: $1" >&2
        rm -Rf "$IMAGE_DIR"
        exit 1
    }

    if [ -z "$1" ]; then
        echo "Usage: $0 <image>[:tag]"
        exit 1
    fi

    parse_image_input "$1"

    echo "Загружаем образ: $REPO_FULL:$TAG"

    IMAGE_DIR="$IMAGES_DIR/$REPO_FULL/$TAG"
    LAYERS_DIR="$IMAGE_DIR/layers"
    MANIFEST_FILE="$IMAGE_DIR/manifest.json"

    mkdir -p "$LAYERS_DIR" || error "Failed to create directory $LAYERS_DIR"

    AUTH_URL="https://auth.docker.io/token?service=registry.docker.io&scope=repository:${REPO_FULL}:pull"
    TOKEN_RESP="$(mktemp)"
    if ! http_get "$AUTH_URL" "$TOKEN_RESP"; then
        rm -f "$TOKEN_RESP"
        error "Не удалось получить токен с $AUTH_URL"
    fi

    TOKEN=$(jq -r '.token' "$TOKEN_RESP")
    rm "$TOKEN_RESP"

    if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
        error "Failed to extract token from an authorization response."
    fi

    HOST_ARCH=$(uname -m)
    case "$HOST_ARCH" in
        x86_64)
            TARGET_ARCH="amd64"
            ;;
        aarch64|arm64)
            TARGET_ARCH="arm64"
            ;;
        *)
            TARGET_ARCH="$HOST_ARCH"
            ;;
    esac
    #echo "Host architecture: $HOST_ARCH -> choose: $TARGET_ARCH"

    MANIFEST_URL="$REGISTRY_URL/v2/${REPO_FULL}/manifests/${TAG}"
    TMP_MANIFEST="$(mktemp)"
    http_get_auth "$MANIFEST_URL" "$TMP_MANIFEST" "application/vnd.docker.distribution.manifest.list.v2+json" || true

    if [ ! -s "$TMP_MANIFEST" ]; then
        rm -f "$TMP_MANIFEST"
        error "Failed to load manifest list from $MANIFEST_URL. It either doesn't exist or the tag $TAG is invalid."
    fi

    if jq -e '.manifests' "$TMP_MANIFEST" >/dev/null 2>&1; then
        #echo "Got manifest list. Looking for $TARGET_ARCH manifest..."
        SELECTED_DIGEST=$(jq -r --arg arch "$TARGET_ARCH" '
        .manifests[]
        | select(.platform.architecture == $arch)
        | .digest' "$TMP_MANIFEST")
        if [ -z "$SELECTED_DIGEST" ] || [ "$SELECTED_DIGEST" = "null" ]; then
            rm -f "$TMP_MANIFEST"
            error "Manifest list doesn't contain manifest for $TARGET_ARCH"
        fi
        #echo "Selected manifest digest: $SELECTED_DIGEST"
        
        http_get_auth "$REGISTRY_URL/v2/${REPO_FULL}/manifests/${SELECTED_DIGEST}" "$TMP_MANIFEST" "application/vnd.docker.distribution.manifest.v2+json"|| error "Не удалось загрузить манифест по digest $SELECTED_DIGEST"
    #else
        #echo "Got single scheme manifest, not manifest list."
    fi

    if jq -e '.errors' "$TMP_MANIFEST" >/dev/null 2>&1; then
        ERR_MSG=$(jq -r '.errors[0].message' "$TMP_MANIFEST")
        rm -f "$TMP_MANIFEST"
        error "Manifest returned error: $ERR_MSG"
    fi

    mv "$TMP_MANIFEST" "$MANIFEST_FILE"
    echo "Manifest was saved at $MANIFEST_FILE"

    mkdir -p "$GLOBAL_LAYERS_DIR" || error "Failed to create directory $GLOBAL_LAYERS_DIR"

    LAYER_DIGESTS=$(jq -r '.layers[].digest' "$MANIFEST_FILE")
    if [ -z "$LAYER_DIGESTS" ]; then
        error "Failed to extract a layer list from manifest $MANIFEST_FILE."
    fi

    echo "Found layers:"
    INDEX=1
    for DIGEST in $LAYER_DIGESTS; do
        echo "    $INDEX	$DIGEST"
        INDEX=$((INDEX+1))
    done

    CONFIG_DIGEST=$(jq -r '.config.digest' "$MANIFEST_FILE")
    if [ -z "$CONFIG_DIGEST" ] || [ "$CONFIG_DIGEST" = "null" ]; then
        error "Failed to get image config from manifest $MANIFEST_FILE."
    fi
    echo "Найден config blob с digest: $CONFIG_DIGEST"

    CONFIG_FILE="$IMAGE_DIR/config.json"

    if command -v curl >/dev/null 2>&1; then
        curl -f -sSL -H "Authorization: Bearer $TOKEN" \
            "$REGISTRY_URL/v2/${REPO_FULL}/blobs/${CONFIG_DIGEST}" -o "$CONFIG_FILE" \
            || error "Не удалось загрузить config blob с digest $CONFIG_DIGEST"
    else
        wget --header="Authorization: Bearer $TOKEN" -qO "$CONFIG_FILE" \
            "$REGISTRY_URL/v2/${REPO_FULL}/blobs/${CONFIG_DIGEST}" \
            || error "Не удалось загрузить config blob с digest $CONFIG_DIGEST"
    fi
    http_get_auth "$REGISTRY_URL/v2/${REPO_FULL}/blobs/${CONFIG_DIGEST}" "$CONFIG_FILE" || error "Couldn't download config blob with digest $CONFIG_DIGEST"

    #echo "Image config is saved at $CONFIG_FILE"

    mkdir -p "$LAYERS_DIR" || error "Couldn't create directory $LAYERS_DIR"

    INDEX=1
    for DIGEST in $LAYER_DIGESTS; do
        SHORT_DIGEST=$(echo "$DIGEST" | sed 's/sha256://')
        GLOBAL_LAYER_PATH="$GLOBAL_LAYERS_DIR/$SHORT_DIGEST"
        REL_GLOBAL_LAYER_PATH="$REL_GLOBAL_LAYERS_DIR/$SHORT_DIGEST"
        TEMP_TAR_FILE="$GLOBAL_LAYER_PATH.tar"
        IMAGE_LAYER_LINK="$LAYERS_DIR/$INDEX"

        # Если глобальная папка уже есть, пропускаем скачивание
        if [ -d "$GLOBAL_LAYER_PATH" ]; then
            echo "Layer $INDEX ($DIGEST) is already cached."
        else
            echo "Downloading layer $INDEX ($DIGEST)..."
            BLOB_URL="$REGISTRY_URL/v2/${REPO_FULL}/blobs/${DIGEST}"
            if ! http_get_auth "$BLOB_URL" "$TEMP_TAR_FILE"; then
                error "Failed to download layer $INDEX ($DIGEST)."
            fi

            #echo "Extracting layer $INDEX ($DIGEST)..."
            mkdir -p "$GLOBAL_LAYER_PATH" || error "Failed to create layer directory $GLOBAL_LAYER_PATH"
            if ! tar -xf "$TEMP_TAR_FILE" -C "$GLOBAL_LAYER_PATH"; then
                error "Error when extracting layer $INDEX ($DIGEST)."
            fi

            rm "$TEMP_TAR_FILE"
        fi

        rm -rf "$IMAGE_LAYER_LINK" 2>/dev/null
        ln -s "$REL_GLOBAL_LAYER_PATH" "$IMAGE_LAYER_LINK" || error "Failed to create symlink for layer $INDEX"

        INDEX=$((INDEX + 1))
    done

    echo "Image $REPO_FULL:$TAG was downloaded successfully."
    #echo "Global layers are in: $GLOBAL_LAYERS_DIR"
    #echo "Layer symlinks are in: $LAYERS_DIR"
}

ensure_image_exists() {
    parse_image_input "$1"
    if [ ! -d "$IMAGES_DIR/$REPO_FULL/$TAG" ]; then
        log "Image $image not found, pulling..."
        nk_pull "$1" || {
            log "Failed to pull image $1"
            exit 1
        }
    fi
}

# delete layers that are not used by any images
nk_layer_prune() {
    set -e

    USED_HASHES=$(find "$IMAGES_DIR" -type l -exec readlink -f {} \; | xargs -I{} basename {} | sort -u)

    if [ -z "$USED_HASHES" ]; then
        echo "Error: No used layers found!"
        exit 1
    fi

    echo "Used layers:"
    echo "$USED_HASHES" | sed 's/^/ - /'

    echo "Starting pruning unused layers..."

    for LAYER_PATH in "$GLOBAL_LAYERS_DIR"/*; do
        [ -d "$LAYER_PATH" ] || continue
        LAYER_HASH=$(basename "$LAYER_PATH")

        if echo "$USED_HASHES" | grep -qx "$LAYER_HASH"; then
            echo "Used layer: $LAYER_PATH"
        else
            echo "Deleting layer: $LAYER_PATH"
            rm -rf "$LAYER_PATH"
        fi
    done

    echo "Pruning is finished."
}


nk_stop() {
    while [ "$1" != "" ]; do
        container_prefix=$1
        container_id=$(find_container "$container_prefix") || eval "shift; continue"
        container_dir="$CONTAINERS_DIR/$container_id"
        meta="$container_dir/metadata.json"

        jq '.stopped = true' "$meta" > tmp && mv tmp "$meta"
        pid=$(jq -r .pid "$meta")

        kill_wait_group $pid 5 2>/dev/null
        if [ $? -eq 1 ]; then
            kill -9 -$pid 2>/dev/null
        fi
        echo "$container_prefix"
        shift
    done
}

nk_kill() {
    signal=""
    while [ "$1" != "" ]; do
        case "$1" in
            --signal=*)
                signal="${1#--signal=}"
                shift
                ;;
            -s)
                shift
                signal="$1"
                shift
                ;;
            *)
                break
                ;;
        esac
    done

    if [ -z "$signal" ]; then
        signal="KILL"
    fi

    while [ "$1" != "" ]; do
        container_prefix="$1"
        container_id=$(find_container "$container_prefix") || { shift; continue; }
        container_dir="$CONTAINERS_DIR/$container_id"
        meta="$container_dir/metadata.json"

        if [ ! -f "$meta" ]; then
            printf "Error: cannot kill container: %s: metadata not found for container %s\n" "$container_prefix" "$container_id" >&2
            shift
            continue
        fi

        status=$(jq -r .status "$meta")
        pid=$(jq -r .pid "$meta")

        if [ "$status" != "running" ]; then
            printf "Error: cannot kill container: %s: container %s is not running\n" "$container_prefix" "$container_id" >&2
            shift
            continue
        fi

        if kill -"$signal" -"$pid" 2>/dev/null; then
            printf "%s\n" "$container_prefix"
        else
            printf "Error: cannot kill container: %s: failed to send signal %s\n" "$container_prefix" "$signal" >&2
        fi

        shift
    done
}


nk_rm() {
    force=0
    remove_volumes=0
    remove_link=0
    while [ "$1" != "" ]; do
        case "$1" in
            --force)
                force=1 ;;
            --volumes)
                remove_volumes=1 ;;
            --link)
                remove_link=1 ;;
            --)
                shift
                break
                ;;
            -*)
                flags="${1#-}"
                while [ -n "$flags" ]; do
                    flag="${flags%"${flags#?}"}"
                    flags="${flags#?}"
                    case "$flag" in
                        f) force=1 ;;
                        l) remove_link=1 ;;
                        v) remove_volumes=1 ;;
                        *)
                            echo "Error: Unknown option '-$flag'" >&2
                            exit 1
                            ;;
                    esac
                done
                ;;
            *)
                break ;;
        esac
        shift
    done

    if [ -z "$1" ]; then
         echo "Usage: $SCRIPT_NAME rm [options] <containers...>"
         exit 1
    fi

    while [ "$1" != "" ]; do
        container_id=$(find_container "$1") || return $?
        
        container_dir="$CONTAINERS_DIR/$container_id"
        meta="$container_dir/metadata.json"

        status=$(jq -r .status "$meta")
        pid=$(jq -r .pid "$meta")
        restart_policy=$(jq -r .restart_policy "$meta")
        
        if [ $force -eq 1 ]; then
            jq '.stopped = true' "$meta" > tmp && mv tmp "$meta"
            kill -9 -$pid 2>/dev/null
            status="exited"
        fi

        if [ "$status" = "running" ]; then
            echo "Error: Container $container_id is running" >&2
            shift
            continue
        fi

        cleanup_container "$container_dir" "$merged_dir"
        rm -Rf "$container_dir"

        # TODO: implement remove_link and remove_volumes

        echo "$container_prefix"
        shift
    done
}

nk_prune() {
    force=0
    filter=""

    while [ "$1" != "" ]; do
        case "$1" in
            --force|-f)
                force=1
                ;;
            --filter)
                filter="$filter $1"
                shift
                ;;
            *)
                break
                ;;
        esac
        shift
    done

    if [ -n "$filter" ]; then
        printf "Ошибка: --filter не реализован\n" >&2
        return 1
    fi

    if [ $force -eq 0 ]; then
        echo WARNING! This will remove all stopped containers.
        if ! prompt_confirmation "Are you sure you want to continue?"; then
            return 1
        fi
    fi

    total_kb=0
    deleted_containers=""

    tmpfile=$(mktemp)

    find "$CONTAINERS_DIR/"* -maxdepth 1 -name metadata.json > "$tmpfile"

    while IFS= read -r meta; do
        #echo "Processing $meta"

        status=$(jq -r .status "$meta")
        if [ "$status" = "exited" ]; then
            container_dir=$(dirname "$meta")
            container_id=$(basename "$container_dir")

            if [ -d "$container_dir/work" ]; then
                size_kb=$(du -sk "$container_dir/work" 2>/dev/null | awk '{print $1}')
            elif [ -d "$container_dir/merged" ]; then
                size_kb=$(du -sk "$container_dir/merged" 2>/dev/null | awk '{print $1}')
            else
                size_kb=0
            fi

            total_kb=$(( total_kb + size_kb ))
            deleted_containers="$deleted_containers
$container_id"

            cleanup_container "$container_dir" "$merged_dir"
            rm -rf "$container_dir"
        fi
    done < "$tmpfile"
    rm -f "$tmpfile"

    if [ -n "$(echo "$deleted_containers" | sed '/^[[:space:]]*$/d')" ]; then
        echo "Deleted Containers:"
        echo "$deleted_containers" | sed '/^[[:space:]]*$/d'
        
        if [ "$total_kb" -lt 1024 ]; then
            hr="${total_kb}kB"
        else
            mb=$(echo "scale=2; $total_kb/1024" | bc)
            hr="${mb}MB"
        fi
        echo
    fi
    printf "Total reclaimed space: %s\n" "$hr"
}

nk_ps() {
    SHOW_ALL="false"
    only_ids=0
    latest=0
    display_sizes=0
    no_trunc=0
    FILTER_STATUS=""
    LAST_COUNT=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --all) SHOW_ALL="true" ;;
            --latest) latest=1 ;;
            --quiet) only_ids=1 ;;
            --size) display_sizes=1 ;;
            --no-trunc) no_trunc=1 ;;
            --filter|-f)
                shift
                if [ -z "$1" ]; then
                    printf "%s\n" "Error: --filter value is not set" >&2
                    exit 1
                fi
                case "$1" in
                    status=*) FILTER_STATUS="${1#status=}"  ;;
                    *) printf "%s\n" "Warning: Filter '$1' is not supported yet and will be ignored." >&2 ;;
                esac
                ;;
            -n|--last)
                shift
                if [ -z "$1" ]; then
                    printf "%s\n" "Error: -n/--last value is not set" >&2
                    exit 1
                fi
                LAST_COUNT="$1"
                ;;
            -*)
                flags=$(printf "%s" "$1" | sed 's/^-//')
                while [ -n "$flags" ]; do
                    flag=${flags%"${flags#?}"}
                    flags=${flags#?}
                    case "$flag" in
                        a) SHOW_ALL="true" ;;
                        q) only_ids=1 ;;
                        l) latest=1 ;;
                        s) display_sizes=1 ;;
                        *)
                            printf "%s\n" "Error: Unknown option '-$flag'" >&2
                            exit 1
                            ;;
                    esac
                done
                ;;
            *)
                break
                ;;
        esac
        shift
    done

    if [ "$latest" -eq 1 ] && [ -z "$LAST_COUNT" ]; then
        LAST_COUNT=1
    fi

    delim=$(printf '\t')

    temp_file=$(mktemp)

    find "$CONTAINERS_DIR/$prefix"* -maxdepth 1 -name metadata.json 2>/dev/null | while read -r meta; do
        IFS="$delim"
        read -r container_id image created status restart_policy stopped pid command exited_at exit_code ports <<EOF
$(jq -r '[.id, (.image | split(":")[0] | .[0:20]), .created, .status, (.restart_policy // "no"), (.stopped // 0), .pid, .command, .exited_at, (.exit_code // -1), (.ports // "none")] | join("'"$delim"'")' "$meta")
EOF

        created_ago=$(time_ago "$created")

        if [ "$status" = "running" ]; then
            if ! ps -p "$pid" >/dev/null 2>&1; then
                status="exited"
                exited_at=$(date -u +"%Y-%m-%dT%H:%M:%S")
                jq --arg exited "$exited_at" '.status = "exited" | .exited_at = $exited' "$meta" > tmp && mv tmp "$meta"
            fi
        fi

        if [ "$SHOW_ALL" != "true" ] && [ "$status" != "running" ]; then
            continue
        fi

        if [ -n "$FILTER_STATUS" ] && [ "$status" != "$FILTER_STATUS" ]; then
            continue
        fi

        if [ "$status" = "exited" ]; then
            exited_ago=$(time_ago "$exited_at")
            if [ "$stopped" != "true" ] && [ "$restart_policy" != "no" ] && { [ "$restart_policy" != "on-failure" ] || [ "$exit_code" -ne 0 ]; }; then
                status_str="Restarting ($exit_code) $exited_ago"
            else
                status_str="Exited ($exit_code) $exited_ago"
            fi
        else
            status_str="Up $created_ago"
        fi

        if [ "$display_sizes" -eq 1 ]; then
            container_dir=$(dirname "$meta")
            if [ -d "$container_dir/work" ]; then
                size=$(du -sh "$container_dir/work" 2>/dev/null | awk '{print $1}')
            elif [ -d "$container_dir/merged" ]; then
                size=$(du -sh "$container_dir/merged" 2>/dev/null | awk '{print $1}')
            else
                size="0"
            fi
        fi

        if [ "$no_trunc" -eq 0 ]; then
            display_container_id=$(printf "%s" "$container_id" | cut -c1-12)
            cmd_len=$(printf "%s" "$command" | wc -c | tr -d ' ')
            if [ "$cmd_len" -le 28 ]; then
                display_command="$command"
            else
                display_command=$(printf "%s" "$command" | cut -c1-25)"..."
            fi
        else
            display_container_id="$container_id"
            display_command="$command"
        fi

        if [ "$ports" = "" ]; then
            ports=" "
        fi

        # Первое поле – created (для сортировки), затем остальные поля.
        line="$created${delim}$display_container_id${delim}$image${delim}$display_command${delim}$created_ago${delim}$status_str${delim}$ports"
        if [ "$display_sizes" -eq 1 ]; then
            line="$line${delim}$size"
        fi
        printf "%s\n" "$line" >> "$temp_file"
    done

    [ ! -s "$temp_file" ] && { rm -f "$temp_file"; return; }

    sorted_file=$(mktemp)
    sort -r -t "$delim" -k1,1 "$temp_file" > "$sorted_file"
    rm "$temp_file"

    if [ -n "$LAST_COUNT" ]; then
        head -n "$LAST_COUNT" "$sorted_file" > "$sorted_file.tmp"
        mv "$sorted_file.tmp" "$sorted_file"
    fi

    if [ "$only_ids" -eq 0 ]; then
        if [ "$display_sizes" -eq 1 ]; then
            printf "%-15s %-20s %-28s %-20s %-25s %-15s %-10s\n" "CONTAINER ID" "IMAGE" "COMMAND" "CREATED" "STATUS" "PORTS" "SIZE"
        else
            printf "%-15s %-20s %-28s %-20s %-25s %-15s\n" "CONTAINER ID" "IMAGE" "COMMAND" "CREATED" "STATUS" "PORTS"
        fi
    fi

    while IFS="$delim" read -r sort_key cid image cmd created_ago status_str ports size; do
        if [ "$only_ids" -eq 1 ]; then
            printf "%s\n" "${cid:- }"
        else
            if [ "$display_sizes" -eq 1 ]; then
                printf "%-15s %-20s %-28s %-20s %-25s %-15s %-10s\n" "${cid:- }" "${image:- }" "${cmd:- }" "${created_ago:- }" "${status_str:- }" "${ports:- }" "${size:- }"
            else
                printf "%-15s %-20s %-28s %-20s %-25s %-15s\n" "${cid:- }" "${image:- }" "${cmd:- }" "${created_ago:- }" "${status_str:- }" "${ports:- }"
            fi
        fi
    done < "$sorted_file"
    rm "$sorted_file"
}

nk_run() {
    interactive=0
    tty_flag=0
    remove=0
    detach=0
    restart_policy="no"
    attach_session=""
    volumes=""
    ports=""
    specified_env_vars=""
    specified_workdir=""
    specified_user=""
    while [ "$1" != "" ]; do
        case "$1" in
            --detach)
                detach=1 ;;
            --rm)
                remove=1 ;;
            -P|--publish-all)
                # TODO: for each exposed port map it to an auto selected free host port
                ;;
            --restart* )
                if echo "$1" | grep -q "="; then
                    restart_policy="${1#*=}"
                else
                    shift
                    restart_policy="$1"
                fi
                ;;
            -v|--volume)
                if [ -n "$2" ]; then
                    volumes="$volumes $2"
                    shift
                else
                    echo "Error: $1 requires an argument" >&2
                    exit 1
                fi
                ;;
            --mount)
                if [ -n "$2" ]; then
                    echo "Warning: $1 is not implemented yet. Use -v instead."
                    shift
                else
                    echo "Error: $1 requires an argument" >&2
                    exit 1
                fi
                ;;
            -p|--publish)
                if [ -n "$2" ]; then
                    ports="$ports $2"
                    shift
                else
                    echo "Error: $1 requires an argument" >&2
                    exit 1
                fi
                ;;
            -e|--env)
                if [ -n "$2" ]; then
                    specified_env_vars="$specified_env_vars $2"
                    shift
                else
                    echo "Error: $1 requires an argument" >&2
                    exit 1
                fi
                ;;
            --env-file)
                if [ -n "$2" ]; then
                    while IFS= read -r line || [ -n "$line" ]; do
                        if [ -z "$line" ] || echo "$line" | grep -qE '^\s*#'; then
                            continue
                        fi
                        specified_env_vars="$specified_env_vars $line"
                    done < "$2"
                    shift
                else
                    echo "Error: $1 requires an argument" >&2
                    exit 1
                fi
                ;;
            -u|--user)
                if [ -n "$2" ]; then
                    specified_user="$2"
                    shift
                else
                    echo "Error: $1 requires an argument" >&2
                    exit 1
                fi
                ;;
            -w|--workdir)
                if [ -n "$2" ]; then
                    specified_workdir="$2"
                    shift
                else
                    echo "Error: $1 requires an argument" >&2
                    exit 1
                fi
                ;;
            --)
                shift
                break
                ;;
            -*)
                flags="${1#-}"
                while [ -n "$flags" ]; do
                    flag="${flags%"${flags#?}"}"
                    flags="${flags#?}"
                    case "$flag" in
                        i) interactive=1 ;;
                        t) tty_flag=1 ;;
                        d) detach=1 ;;
                        *)
                            echo "Error: Unknown option '-$flag'" >&2
                            exit 1
                            ;;
                    esac
                done
                ;;
            *)
                break
                ;;
        esac
        shift
    done

    if [ -z "$1" ]; then
         echo "Usage: $SCRIPT_NAME run [options] IMAGE [COMMAND]"
         exit 1
    fi

    image=$1
    shift

    ensure_image_exists "$image"

    IFS='|' read -r env_vars workdir user final_cmd <<EOF
$(parse_image_config "$image" "$*")
EOF

    container_id=$(generate_container_id)
    container_dir="$CONTAINERS_DIR/$container_id"
    mkdir -p "$container_dir"

    log_file="$container_dir/container.log"
    meta="$container_dir/metadata.json"

    if [ "$detach" -eq 1 ] && [ "$tty_flag" -eq 1 ]; then
         attach_session="nk_$container_id"
    fi

    env_vars="$specified_env_vars $env_vars"
    if [ -n "$specified_workdir" ]; then
        workdir="$specified_workdir"
    fi
    if [ -n "$specified_user" ]; then
        user="$specified_user"
    fi

    save_metadata "$container_dir" "$container_id" "$image" "$final_cmd" "$workdir" "$env_vars" "$user" "$restart_policy" "$attach_session" "$volumes" "$ports"

    mount_image_layers "$image" "$container_dir"
    merged_dir="$container_dir/merged"

    mkdir -p "$merged_dir/etc"
    for file in resolv.conf host.conf hosts nsswitch.conf; do
        cp "/etc/$file" "$merged_dir/etc/" > /dev/null 2>&1
    done

    #log "Starting container $container_id: $final_cmd"

    run_container() {
        CMD="run_in_container $(shell_quote "$container_id") \
            $(shell_quote "$workdir") \
            $(shell_quote "$env_vars") \
            $(shell_quote "$user") \
            $(shell_quote "$interactive") \
            $(shell_quote "$tty_flag") \
            $(shell_quote "$volumes") \
            $(shell_quote "$ports") \
            $(shell_quote "true") \
            $(shell_quote "$final_cmd")"
        if [ "$detach" -eq 1 ]; then
            if [ "$tty_flag" -eq 1 ]; then
                tmux new-session -d -s "$attach_session" sh -c ". \"$LIB_PATH\"; $CMD 2>&1 | tee \"$log_file\""
                while tmux has-session -t "$attach_session" 2>/dev/null; do
                    sleep 1
                done
            else
                eval "$CMD" >> "$log_file" 2>&1
            fi
         else
            eval "$CMD" #| tee -a "$log_file"
            return $?
         fi
    }

    container_monitor() {
        while true; do
            if [ "$(jq -r '.stopped // false' "$meta")" = "true" ]; then
                log "Container $container_id has been manually stopped. Exiting monitor."
                break
            fi
            run_container
            rc=$?
            if [ "$restart_policy" = "on-failure" ] && [ $rc -eq 0 ]; then
                break
            fi
            if [ "$restart_policy" = "no" ]; then
                break
            fi
            log "Container $container_id exited with code $rc, restarting in 1 second..." >> "$log_file" 2>&1
            sleep 1
        done
        cleanup_container "$container_dir" "$merged_dir"
        if [ $remove -eq 1 ]; then
           rm -Rf "$container_dir"
        fi
    }

    if [ "$detach" -eq 1 ]; then
        echo before container_monitor \&, pid = $$
        container_monitor &
        monitor_pid=$!
        log "Container $container_id started in detached mode with restart policy '$restart_policy' (monitor pid: $monitor_pid)"
        echo "$container_id"
        exit 0
    else
        run_container
        rc=$?

        if [ "$restart_policy" != "no" ]; then
            detach=1
            log "Container $container_id exited with code $rc, starting monitor in background according to restart policy '$restart_policy'..."
            container_monitor &
            monitor_pid=$!
            log "Monitor for container $container_id started (pid: $monitor_pid)"
            echo "$container_id"
            exit 0
        else
            cleanup_container "$container_dir" "$merged_dir"
        fi
    fi

    exit $rc
}

nk_start() {
    interactive=0

    while [ "$1" != "" ]; do
        case "$1" in
            -i) interactive=1 ;;
            --) shift; break ;;
            -*)
                echo "Неизвестная опция: $1"
                exit 1
                ;;
            *) break ;;
        esac
        shift
    done

    if [ -z "$1" ]; then
        echo "Usage: $SCRIPT_NAME start CONTAINER_ID"
        exit 1
    fi
    container_prefix=$1
    container_id=$(find_container "$container_prefix") || return $?

    shift
    while [ "$1" != "" ]; do
        case "$1" in
            -i) interactive=1 ;;
            --) shift; break ;;
            -*)
                echo "Неизвестная опция: $1"
                exit 1
                ;;
            *) break ;;
        esac
        shift
    done

    container_dir="$CONTAINERS_DIR/$container_id"
    meta="$container_dir/metadata.json"
    if [ ! -f "$meta" ]; then
        log "Error: Container $container_id not found"
        exit 1
    fi

    jq 'del(.stopped)' "$meta" > tmp && mv tmp "$meta"

    IFS="$(printf '\t')"
read -r image workdir env_vars status volumes ports command <<EOF
$(jq -r '[.image, .workdir, (.env | join(" ")), .status, (.volumes // ""), (.ports // ""), .command] | @tsv' "$meta")
EOF

    mount_image_layers "$image" "$container_dir"
    merged_dir="$container_dir/merged"

    #log "Starting container $container_id: $command"

    run_in_container "$container_id" "$workdir" "$env_vars" "$interactive" 0 "$volumes" "$ports" "true" "$command"

    cleanup_container "$container_dir" "$merged_dir"
}

nk_restart() {
    nk_stop "$@"
    nk_start "$@"
}

nk_exec() {
    interactive=0
    tty_flag=0
    detach=0

    while [ "$1" != "" ]; do
        case "$1" in
            --detach) detach=1 ;;
            --) shift; break ;;
            -*)
                flags="${1#-}"
                while [ -n "$flags" ]; do
                    flag="${flags%"${flags#?}"}"
                    flags="${flags#?}"
                    case "$flag" in
                        i) interactive=1 ;;
                        t) tty_flag=1 ;;
                        d) detach=1 ;;
                        *)
                            echo "Error: Unknown option '-$flag'" >&2
                            exit 1
                            ;;
                    esac
                done
                ;;
            *) break ;;
        esac
        shift
    done

    if [ $# -lt 1 ]; then
        echo "Usage: $SCRIPT_NAME exec [options] <container_id_prefix> COMMAND [ARGS...]"
        exit 1
    fi

    container_prefix=$1
    container_id=$(find_container "$container_prefix") || return $?
    shift
    cmd="$*"

    container_dir="$CONTAINERS_DIR/$container_id"
    meta="$container_dir/metadata.json"
    if [ ! -f "$meta" ]; then
        log "Error: Container $container_id not found"
        exit 1
    fi

    IFS="$(printf '\t')"
read -r workdir env_vars status volumes ports <<EOF
$(jq -r '[.workdir, (.env | join(" ")), .status, (.volumes // ""), (.ports // "")] | @tsv' "$meta")
EOF

    if [ "$status" != "running" ]; then
        log "Error: Container $container_id is not running (status: $status)"
        exit 1
    fi

    #log "Executing in container $container_id: $cmd"
    run_in_container "$container_id" "$workdir" "$env_vars" "$interactive" "$tty_flag" "$volumes" "$ports" "false" "$cmd"
}

nk_attach() {
    if [ $# -lt 1 ]; then
        echo "Usage: $SCRIPT_NAME attach CONTAINER_ID"
        exit 1
    fi

    container_prefix=$1
    container_id=$(find_container "$container_prefix") || return $?
    container_dir="$CONTAINERS_DIR/$container_id"
    meta="$container_dir/metadata.json"

    if [ ! -f "$meta" ]; then
        echo "Error: Container $container_id not found"
        exit 1
    fi

    attach_session=$(jq -r '.attach_session // empty' "$meta")
    if [ -z "$attach_session" ]; then
        echo "Error: Container $container_id does not support attach (attach_session not set)."
        exit 1
    fi

    if ! command -v tmux >/dev/null 2>&1; then
        echo "Error: tmux is required for attach but not found."
        exit 1
    fi

    tmux attach-session -t "$attach_session"
}

nk_logs() {
    follow=false
    tail_lines="all"
    container_id=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -f|--follow)
                follow=true
                shift
                ;;
            -n|--tail)
                if [ $# -lt 2 ]; then
                    echo "Error: $1 requires an argument" >&2
                    exit 1
                fi
                tail_lines="$2"
                shift 2
                ;;
            --since|--until)
                echo "Warning: $1 is not supported" >&2
                if [ $# -lt 2 ]; then
                    echo "Error: $1 requires an argument" >&2
                    exit 1
                fi
                shift 2
                ;;
            --details|-t|--timestamps)
                echo "Warning: $1 is not supported" >&2
                shift
                ;;
            -*)
                echo "Error: Unknown option $1" >&2
                exit 1
                ;;
            *)
                if [ -z "$container_id" ]; then
                    container_id="$1"
                    shift
                else
                    echo "Error: Multiple container IDs specified: $container_id and $1" >&2
                    exit 1
                fi
                ;;
        esac
    done

    if [ -z "$container_id" ]; then
        echo "Usage: $SCRIPT_NAME logs [OPTIONS] CONTAINER_ID" >&2
        exit 1
    fi

    if [ "$tail_lines" != "all" ]; then
        case $tail_lines in
            ''|*[!0-9]*)
                echo "Error: --tail requires a numeric argument or 'all'" >&2
                exit 1
                ;;
        esac
    fi

    container_id=$(find_container "$container_id") || exit $?
    container_dir="$CONTAINERS_DIR/$container_id"
    log_file="$container_dir/container.log"

    if [ ! -f "$log_file" ]; then
        echo "No log file for container $container_id." >&2
        exit 1
    fi

    if [ "$follow" = true ]; then
        if [ "$tail_lines" = "all" ]; then
            cmd="tail -n +1 -f"
        else
            cmd="tail -n $tail_lines -f"
        fi
    else
        if [ "$tail_lines" = "all" ]; then
            cmd="cat"
        else
            cmd="tail -n $tail_lines"
        fi
    fi

    $cmd "$log_file"
}

nk_inspect() {
    if [ $# -lt 1 ]; then
        echo "Usage: $SCRIPT_NAME inspect CONTAINER_ID"
        exit 1
    fi

    container_prefix=$1
    container_id=$(find_container "$container_prefix") || return $?
    container_dir="$CONTAINERS_DIR/$container_id"
    meta="$container_dir/metadata.json"

    if [ ! -f "$meta" ]; then
        echo "Not found."
        exit 1
    fi

    cat "$meta"
}

extract_workdir_from_overlay() {
    lower_dirs="$1"
    merged_dir_path="$2"
    workdir_path="$3"

    #rsync -a --compare-dest="$lower_dir" "$new_dir"/ "$workdir_path"/

    cd "$merged_dir" || exit 1

    IFS=' '

    find . -type f | while read -r file; do
        # Инициализируем переменную для отслеживания наличия файла в lower_dirs
        found_in_lower=0
        
        for lower_dir in $lower_dirs; do
            if [ -f "$lower_dir/$file" ]; then
                found_in_lower=1
                sum_new=$(md5sum "$file" | awk '{print $1}')
                sum_old=$(md5sum "$lower_dir/$file" | awk '{print $1}')
                if [ "$sum_new" != "$sum_old" ]; then
                    mkdir -p "$(dirname "$workdir_path/$file")"
                    cp -p "$file" "$workdir_path/$file"
                fi
                # Если файл совпадает, прерываем цикл
                break
            fi
        done
        
        # Если файл не найден ни в одной из lower_dirs, копируем его
        if [ "$found_in_lower" -eq 0 ]; then
            mkdir -p "$(dirname "$workdir_path/$file")"
            cp -p "$file" "$workdir_path/$file"
        fi
    done

    # Создание whiteout-файлов AUFS для удалённых файлов
    # TODO: for overlayfs compatibility create character devices instead
    for lower_dir in $lower_dirs; do
        find "$lower_dir" -type f | while read -r lower_file; do
            # Преобразуем путь к файлу в lower_dir, чтобы он соответствовал структуре new_dir
            relative_path="${lower_file#"$workdir_path"/}"
            if [ ! -f "$merged_dir_path/$relative_path" ]; then
                # Создаём whiteout-файл в workdir_path
                mkdir -p "$(dirname "$workdir_path/$relative_path")"
                touch "$workdir_path/$relative_path.wh..wh..opq"
            fi
        done
    done

    cd -
}

# Basic primitive to implement commit and build: turn writable container layer into a new image layer
commit_layer() {
    container_id="$1"
    new_layer_hash="$2" # must depend on last layer's hash and all other input data to generate new layer (all Dockerfile commands since last layer)
    dst_image="$3"
    rebase=0

    if [ -z "$dst_image" ]; then
        rebase=1
        dst_image=$(jq -r '.image')
    fi

    parse_image_input "$dst_image"
    
    dst_image_dir="$IMAGES_DIR/$REPO_FULL/$TAG"
    container_dir="$CONTAINERS_DIR/$container_id"

    layer_index=$(find "$dst_image_dir/layers" -mindepth 1 -maxdepth 1 -type d -follow -exec basename {} \; | sort -n | tail -n 1)
    layer_index=$(( ${layer_index:-0} + 1 ))
    new_layer_dir="$GLOBAL_LAYERS_DIR/$new_layer_hash"
    mkdir -p "$new_layer_dir"

    if [ "$USE_OVERLAYFS" -eq 1 ]; then
        umount "$merged_dir"
        if [ "$rebase" -eq 1 ]; then
            mv "$container_dir/work/*" "$new_layer_dir/"
        fi
        mount_image_layers_overlay "$container_dir" "$dst_image_dir/layers"
    else
        set_lower_dirs_for_image "$dst_image_dir/layers"
        extract_workdir_from_overlay "$lower_dirs" "$container_dir/merged" "$new_layer_dir"
    fi
    ln -sf "$REL_GLOBAL_LAYERS_DIR/$new_layer_hash" "$dst_image_dir/layers/$layer_index"
}

nk_commit() {
    container_id="$1"
    new_image_name="$2"
    new_layer_hash=sum_new=$(date +%s | sha256sum | awk '{print $1}')

    parse_image_input "$new_image_name"
    dst_image_dir="$IMAGES_DIR/$REPO_FULL/$TAG"

    base_image=$(jq -r '.image')
    parse_image_input "$base_image"
    base_image_dir="$IMAGES_DIR/$REPO_FULL/$TAG"

    cp -R "$base_image_dir" "$dst_image_dir"

    commit_layer "$container_id" "$new_layer_hash" "$new_image_name"
}

nk_build() {
    dockerfile=${1:-Dockerfile}
    new_image_name=$2

    # Создаём временный каталог для контекста сборки (копируем исходные файлы)
    build_context=$(mktemp -d)
    cp -a . "$build_context"

    # Каталог, где будем накапливать итоговую файловую систему образа
    build_fs=$(mktemp -d)
    # Изначально, если Dockerfile начинается с FROM, базовый образ копируется в build_fs

    new_image_dir="$IMAGES_DIR/$REPO_FULL/$new_image_name"

    layer_index=1

    workdir="/"
    env_vars=""
    volumes=""
    ports=""
    lower_layers=""

    while read -r line; do
        case "$line" in
            FROM\ *)
                base_image=$(echo "$line" | awk '{print $2}')
                ensure_image_exists "$base_image"
                base_image_dir="$IMAGES_DIR/$REPO_FULL/$TAG"
                if [ ! -d "$base_latest_dir" ]; then
                    echo "Error: Base image $base_image not found." >&2
                    exit 1
                fi
                rm -rf "${build_fs:?}"/*
                cp -a "$base_image_dir/layers"/. "$new_image_dir/layers"/
                mount_image_layers "$base_image" "$build_fs"
                ;;
            RUN\ *)
                cmd=$(echo "$line" | cut -d' ' -f2-)
                tmp_container=$(mktemp -d)
                cp -a "$build_fs"/. "$tmp_container"/
                run_in_container "$tmp_container" "$workdir" "$env_vars" "false" "0" "$volumes" "$ports" "false" "$cmd"
                
                layer_hash=$(prepare_build_delta "$build_fs" "$tmp_container")
                
                image_layers_dir="$IMAGES_DIR/built/$tag/latest/layers"
                mkdir -p "$image_layers_dir"
                
                commit_layer "$tmp_container" "$layer_hash" "$new_image_name"
                ;;
            COPY\ *|ADD\ *)
                src=$(echo "$line" | awk '{print $2}')
                dest=$(echo "$line" | awk '{print $3}')
                cp -a "$build_context/$src" "$build_fs/$dest"
                tmp_container=$(mktemp -d)
                cp -a "$build_fs"/. "$tmp_container"/
                layer_hash=$(prepare_build_delta "$build_fs" "$tmp_container")

                image_layers_dir="$IMAGES_DIR/$tag/layers"
                mkdir -p "$image_layers_dir"
                ln -sf "$REL_GLOBAL_LAYERS_DIR/$layer_hash" "$image_layers_dir/$layer_index"
                layer_index=$((layer_index + 1))
                rm -rf "$tmp_container"
                ;;
            *)
                # Пропускаем комментарии и пустые строки
                ;;
        esac
    done < "$dockerfile"

    # Финальная сборка образа: перемещаем содержимое build_fs в IMAGES_DIR/<tag>/latest
    image_latest="$IMAGES_DIR/built/$tag/latest"
    rm -rf "$image_latest"
    mkdir -p "$image_latest"
    cp -a "$build_fs"/. "$image_latest"/

    log "Image built: $tag"

    rm -rf "$build_context"
    rm -rf "$build_fs"
}

nk_build_old() {
    dockerfile=${1:-Dockerfile}
    tag=$2

    # Создаём временный каталог для контекста сборки (копируем исходные файлы)
    build_context=$(mktemp -d)
    cp -a . "$build_context"

    # Каталог, где будем накапливать итоговую файловую систему образа
    build_fs=$(mktemp -d)
    # Изначально, если Dockerfile начинается с FROM, базовый образ копируется в build_fs

    layer_index=1

    workdir="/"
    env_vars=""
    volumes=""
    ports=""
    lower_layers=""

    while read -r line; do
        case "$line" in
            FROM\ *)
                base_image=$(echo "$line" | awk '{print $2}')
                #parse_image_input "$base_image"
                ensure_image_exists "$base_image"
                base_latest="$IMAGES_DIR/$REPO_FULL/$TAG"
                if [ ! -d "$base_latest" ]; then
                    echo "Error: Base image $base_image not found." >&2
                    exit 1
                fi
                # Копируем базовую файловую систему в build_fs
                rm -rf "${build_fs:?}"/*
                cp -a "$base_latest"/. "$build_fs"/
                ;;
            RUN\ *)
                cmd=$(echo "$line" | cut -d' ' -f2-)
                tmp_container=$(mktemp -d)
                cp -a "$build_fs"/. "$tmp_container"/
                run_in_container "$tmp_container" "$workdir" "$env_vars" "false" "0" "$volumes" "$ports" "false" "$cmd"
                
                layer_hash=$(prepare_build_delta "$build_fs" "$tmp_container")
                
                image_layers_dir="$IMAGES_DIR/built/$tag/latest/layers"
                mkdir -p "$image_layers_dir"
                
                ln -sf "$REL_GLOBAL_LAYERS_DIR/$layer_hash" "$image_layers_dir/$layer_index"
                layer_index=$((layer_index + 1))
                
                rm -rf "${build_fs:?}"/*
                cp -a "$tmp_container"/. "$build_fs"/
                rm -rf "$tmp_container"
                ;;
            COPY\ *|ADD\ *)
                src=$(echo "$line" | awk '{print $2}')
                dest=$(echo "$line" | awk '{print $3}')
                cp -a "$build_context/$src" "$build_fs/$dest"
                tmp_container=$(mktemp -d)
                cp -a "$build_fs"/. "$tmp_container"/
                layer_hash=$(prepare_build_delta "$build_fs" "$tmp_container")

                image_layers_dir="$IMAGES_DIR/$tag/layers"
                mkdir -p "$image_layers_dir"
                ln -sf "$REL_GLOBAL_LAYERS_DIR/$layer_hash" "$image_layers_dir/$layer_index"
                layer_index=$((layer_index + 1))
                rm -rf "$tmp_container"
                ;;
            *)
                # Пропускаем комментарии и пустые строки
                ;;
        esac
    done < "$dockerfile"

    # Финальная сборка образа: перемещаем содержимое build_fs в IMAGES_DIR/<tag>/latest
    image_latest="$IMAGES_DIR/built/$tag/latest"
    rm -rf "$image_latest"
    mkdir -p "$image_latest"
    cp -a "$build_fs"/. "$image_latest"/

    log "Image built: $tag"

    rm -rf "$build_context"
    rm -rf "$build_fs"
}

