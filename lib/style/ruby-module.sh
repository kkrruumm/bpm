# build_style=ruby-module - setup.rb
style_configure() { ruby -Ilib setup.rb config --prefix=/usr ${configure_args:-}; }
style_build() { ruby -Ilib setup.rb setup ${make_build_args:-}; }
style_install() { ruby -Ilib setup.rb install --prefix="$DESTDIR" ${make_install_args:-}; }
