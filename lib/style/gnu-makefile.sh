# build_style=gnu-makefile - plain makefile, no configure step
style_build() {
    $make_cmd $make_jobs PREFIX=/usr ${make_build_args:-} ${make_build_target:-}
}
style_check() { $make_cmd PREFIX=/usr ${make_check_args:-} "${make_check_target:-check}"; }
style_install() {
    $make_cmd DESTDIR="$DESTDIR" PREFIX=/usr MANPREFIX=/usr/share/man \
        ${make_install_args:-} "${make_install_target:-install}"
}
