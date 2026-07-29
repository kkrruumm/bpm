# build_style=gemspec - build a gem, then unpack it into the dest_dir
style_build() { gem build ${gem_spec:-*.gemspec}; }
style_install() {
    _gemdir=$(ruby -e 'print Gem.default_dir' 2>/dev/null || echo /usr/lib/ruby/gems)
    gem install --local --install-dir "$DESTDIR$_gemdir" --bindir "$DESTDIR/usr/bin" \
        --no-document --ignore-dependencies ${make_install_args:-} ./*.gem
    rm -rf "$DESTDIR$_gemdir/cache"
}
