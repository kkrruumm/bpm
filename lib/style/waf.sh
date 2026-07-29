# build_style=waf
style_configure() {
    python3 ./waf configure --prefix=/usr --libdir=/usr/lib ${configure_args:-}
}
style_build() { python3 ./waf build "-j$BPM_JOBS" ${make_build_args:-}; }
style_check() { python3 ./waf ${make_check_target:-check} ${make_check_args:-}; }
style_install() { python3 ./waf install --dest_dir="$DESTDIR" ${make_install_args:-}; }
