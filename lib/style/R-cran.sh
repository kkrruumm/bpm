# build_style=R-cran - CRAN source package
style_build() { :; }
style_install() {
    _lib=/usr/lib/R/library
    mkdir -p "$DESTDIR$_lib"
    R CMD INSTALL --library="$DESTDIR$_lib" --no-byte-compile ${make_install_args:-} .
}
