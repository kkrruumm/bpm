# build_style=python3-pep517 - PEP 517 wheel, installed with python-installer
style_build() { python3 -m build --wheel --no-isolation ${make_build_args:-}; }
style_check() { python3 -m pytest ${make_check_args:-}; }
style_install() {
    python3 -m installer --destdir="$DESTDIR" --prefix=/usr \
        ${make_install_args:-} dist/*.whl
}
