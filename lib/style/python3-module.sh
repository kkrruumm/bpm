# build_style=python3-module - setuptools/distutils setup.py
#
# the install paths are pinned explicitly, distro patched setuptools (Debian
# and friends) otherwise defaults to /usr/local and dist-packages, which is
# not what a package should ever contain
_py_purelib() {
    python3 -c 'import sysconfig; print(sysconfig.get_path("purelib", "posix_prefix", vars={"base":"/usr","platbase":"/usr"}))'
}
style_build() { python3 setup.py build ${make_build_args:-}; }
style_check() { python3 -m pytest ${make_check_args:-}; }
style_install() {
    python3 setup.py install \
        --prefix=/usr \
        --root="$DESTDIR" \
        --install-lib="$(_py_purelib)" \
        --install-scripts=/usr/bin \
        --skip-build --optimize=1 ${make_install_args:-}
}
