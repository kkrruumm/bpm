# build_style=cargo - `cargo install` handles the staging, so DESTDIR is
# expressed as the install root
# needs allow_network=yes unless the crates are
# vendored into the build tree
style_build() {
    cargo build --release --locked "-j$BPM_JOBS" ${cargo_args:-} ${make_build_args:-}
}
style_check() { cargo test --release --locked ${cargo_args:-} ${make_check_args:-}; }
style_install() {
    cargo install --path "${cargo_install_path:-.}" --root "$DESTDIR/usr" \
        --locked --no-track ${cargo_args:-} ${make_install_args:-}
    # older cargo ignores --no-track
    rm -f "$DESTDIR/usr/.crates.toml" "$DESTDIR/usr/.crates2.json"
}
