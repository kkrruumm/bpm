# build_style=meta - no sources, no build, the package is pure metadata
style_build() { :; }
style_install() { bmkdir "/usr/share/doc/$pkg_name"; }
