# build_style=haskell-stack - usually needs allow_network=yes unless the
# package index and dependencies are already vendored into the build tree
style_build() {
    stack ${stackage:+--resolver "$stackage"} --system-ghc --skip-ghc-check \
        --jobs "$BPM_JOBS" build ${make_build_args:-}
}
style_check() { stack --system-ghc --skip-ghc-check test ${make_check_args:-}; }
style_install() {
    stack ${stackage:+--resolver "$stackage"} --system-ghc --skip-ghc-check \
        --local-bin-path "$DESTDIR/usr/bin" install ${make_install_args:-}
}
