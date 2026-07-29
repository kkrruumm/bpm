# build_style=configure - a hand written ./configure that is not autotools
style_configure() {
    : "${configure_script:=./configure}"
    $configure_script --prefix=/usr ${configure_args:-}
}
style_build() { $make_cmd $make_jobs ${make_build_args:-} ${make_build_target:-}; }
style_check() { $make_cmd ${make_check_args:-} "${make_check_target:-check}"; }
style_install() { $make_cmd DESTDIR="$DESTDIR" ${make_install_args:-} "${make_install_target:-install}"; }
