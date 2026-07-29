# build_style=cmake - configures into ./build
style_configure() {
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_INSTALL_SYSCONFDIR=/etc \
        -DCMAKE_INSTALL_LOCALSTATEDIR=/var \
        -DCMAKE_BUILD_TYPE="${cmake_build_type:-Release}" \
        -DCMAKE_C_FLAGS="$CFLAGS" -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
        -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
        ${configure_args:-}
}
style_build() { cmake --build build --parallel "$BPM_JOBS" ${make_build_args:-}; }
style_check() { ( cd build && ctest --output-on-failure ${make_check_args:-} ); }
style_install() { DESTDIR="$DESTDIR" cmake --install build ${make_install_args:-}; }
