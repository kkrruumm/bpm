# build_style=fetch - dist_files are installed as they are, never extracted
# the template must provide do_install()
style_extract() {
    for _d in ${dist_files:-}; do
        cp -f "$src_dir/$(dist_name "$_d")" "$build_dir"
    done
}
style_build() { :; }
style_install() { die "build_style=fetch requires a do_install() in the template"; }
