# build_style=perl-module - ExtUtils::MakeMaker
style_configure() {
    perl Makefile.PL INSTALLDIRS=vendor PREFIX=/usr ${configure_args:-}
}
style_build() { $make_cmd $make_jobs ${make_build_args:-}; }
style_check() { $make_cmd test ${make_check_args:-}; }
style_install() {
    $make_cmd DESTDIR="$DESTDIR" ${make_install_args:-} install
    perl_cleanup
}
# perl scatters these through every vendor directory, none of them belong in a
# package, and .packlist would collide between packages
perl_cleanup() {
    find "$DESTDIR" \( -name .packlist -o -name perllocal.pod \) -exec rm -f {} + 2>/dev/null || :
    find "$DESTDIR" -type d -empty -delete 2>/dev/null || :
}
