# build_style=go
# go_package      what to build, default ./... (go_import_path is accepted too)
# go_build_tags  -tags
# go_ldflags     -ldflags, kept as one word so "-s -w" survives
# go_mod_mode    -mod=<mode>
style_build() {
    export GOPATH="$build_dir/.gopath"
    export GOBIN="$build_dir/.gobin"
    export GOFLAGS="${GOFLAGS:--trimpath}"
    export GO111MODULE="${GO111MODULE:-on}"
    export CGO_ENABLED="${CGO_ENABLED:-1}"
    export CGO_CFLAGS="$CFLAGS" CGO_LDFLAGS="$LDFLAGS"
    mkdir -p "$GOBIN"

    set -- build -o "$GOBIN/"
    if [ -n "${go_mod_mode:-}" ]; then set -- "$@" "-mod=$go_mod_mode"; fi
    if [ -n "${go_build_tags:-}" ]; then set -- "$@" -tags "$go_build_tags"; fi
    if [ -n "${go_ldflags:-}" ]; then set -- "$@" -ldflags "$go_ldflags"; fi
    go "$@" ${make_build_args:-} ${go_package:-${go_import_path:-./...}}
}
style_check() { go test ${make_check_args:-} ${go_package:-./...}; }
style_install() {
    for _b in "$build_dir/.gobin"/*; do
        if [ -f "$_b" ]; then bbin "$_b"; fi
    done
}
