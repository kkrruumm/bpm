# build_style=gnu-configure - autoconf style ./configure
style_configure() {
    : "${configure_script:=./configure}"
    # --runstatedir isnt a thing on autoconf 2.69 so detect
    _runstatedir=
    if $configure_script --help 2>/dev/null | grep -q -- '--runstatedir'; then
        _runstatedir=--runstatedir=/run
    fi
    $configure_script \
        --prefix=/usr \
        --bindir=/usr/bin \
        --sbindir=/usr/bin \
        --libdir=/usr/lib \
        --libexecdir=/usr/libexec \
        --includedir=/usr/include \
        --datarootdir=/usr/share \
        --mandir=/usr/share/man \
        --sysconfdir=/etc \
        --localstatedir=/var \
        $_runstatedir \
        ${configure_args:-}
}
style_build() { $make_cmd $make_jobs ${make_build_args:-} ${make_build_target:-}; }
style_check() { $make_cmd ${make_check_args:-} "${make_check_target:-check}"; }
style_install() { $make_cmd DESTDIR="$DESTDIR" ${make_install_args:-} "${make_install_target:-install}"; }
