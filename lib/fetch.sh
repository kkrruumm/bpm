# bpm sources
#
# dist_files entries:
#   https://host/path/file.tar.gz           checksummed download
#   https://host/download?v=1>foo-1.tar.gz  saved as the name after >
#   git+https://host/repo.git#tag           git checkout
#   file:///absolute/path.tar.gz            local file

# the name a dist_files entry is stored under in $src_dir
dist_name() (
    case $1 in
        *'>'*) printf '%s\n' "${1##*>}" ;;
        git+*) dist_url=${1%%#*}; dist_url=${dist_url%.git}; printf '%s\n' "${dist_url##*/}" ;;
        *) dist_url=${1%%\?*}; printf '%s\n' "${dist_url##*/}" ;;
    esac
)

fetch_url() {
    sub "fetch $1"
    case $1 in
        file://*) cp -f "${1#file://}" "${2}.part" ;;
        *) have curl || die "curl not found"
            killable curl -fsSL --retry 4 --retry-delay 10 -o "${2}.part" "$1" ||
                die "download failed: $1" ;;
    esac

    mv -f "${2}.part" "$2"
}

fetch_git() {
    git_url=${1#git+} git_ref=HEAD
    case $git_url in
        *'#'*) git_ref=${git_url##*#}; git_url=${git_url%%#*} ;;
    esac

    if [ -d "${2}/.git" ]; then
        sub "update $git_url"
        killable git -C "$2" fetch -q --tags origin
    else
        sub "clone $git_url"
        killable git clone -q "$git_url" "$2"
    fi

    git -C "$2" checkout -q --detach "$git_ref"
    killable git -C "$2" submodule -q update --init --recursive
    unset git_url git_ref
}

# with a template loaded so __
src_fetch() {
    mkdir -p "$src_dir"
    for __dist in ${dist_files:-}; do
        __file=$src_dir/$(dist_name "$__dist")
        case $__dist in
            git+*) fetch_git "$__dist" "$__file" ;;
            *) [ -f "$__file" ] || fetch_url "${__dist%%>*}" "$__file" ;;
        esac
    done
    unset __dist __file
}

# checksums should have a blake3 hash for each dist_files entry in the
# same order, otherwise SKIP does what it says on the tin
src_verify() {
    set -- ${checksum:-}
    for dist in ${dist_files:-}; do
        want=${1:-}
        [ $# -eq 0 ] || shift
        case $dist in
            git+*) continue ;;
        esac

        file=$src_dir/$(dist_name "$dist")
        [ -n "$want" ] || die "$pkg_name: missing checksum for ${file##*/}"
        [ "$want" != SKIP ] || continue

        got=$(blake3 "$file")
        [ -n "$got" ] || die "$pkg_name: could not hash ${file##*/}"

        case $want in
            "$got"*) ;;
            *) die "$pkg_name: blake3 mismatch for ${file##*/}
        expected $want
        got      $got" ;;
        esac
    done
    unset dist want file got
}

# each job gets its own subshell
# so killing its pid hits the killable() inside
fetch_job() {
    # remove any logs from prior attempts
    rm -f "${BPM_LOGDIR}/${1}.fetch.log"

    (
        trap 'kill "$killable_pid" 2>/dev/null; exit 143' TERM
        exec > "${BPM_LOGDIR}/${1}.fetch.log" 2>&1
        tmpl_load "$1"
        if have do_fetch; then
            do_fetch
        else
            src_fetch
        fi

        src_verify
    ) &
}

# waits on the oldest job, POSIX has no way to wait for whichever finishes first
fetch_reap() {
    job=${fetch_jobs# }; job=${job%% *}
    fetch_jobs=${fetch_jobs#" $job"}
    running=$((running - 1))
    status=0
    wait "${job%%:*}" || status=$?
    job_pkg=${job#*:}

    if [ "$status" = 0 ]; then
        result="${c_ok}ok${c_off}"
    else
        result="${c_err}failed${c_off}"
        failed="$failed $job_pkg"
    fi

    clear=
    spinner_wanted && clear='\r\033[K'
    printf "$clear${c_info}   ->${c_off} %s $result\n" "$job_pkg" >&2
    unset job status job_pkg result clear
}

# prefetch <pkg>... - fetch and verify sources BPM_FETCH_JOBS at a time
# each of these gets logged to $BPM_LOGDIR/<pkg>.fetch.log
prefetch() {
    [ $# -gt 0 ] || return 0
    msg "fetching sources for $# package(s), parallel: $BPM_FETCH_JOBS"
    spinner_start fetching
    running=0 failed=

    for pkg; do
        fetch_job "$pkg"
        fetch_jobs="$fetch_jobs $!:$pkg"
        running=$((running + 1))
        [ "$running" -ge "$BPM_FETCH_JOBS" ] && fetch_reap
    done

    while [ -n "$fetch_jobs" ]; do
        fetch_reap
    done
    spinner_stop

    for pkg in $failed; do
        log_tail "${BPM_LOGDIR}/${pkg}.fetch.log"
    done
    [ -z "$failed" ] || die "failed to fetch:$failed"

    unset running failed pkg
}
