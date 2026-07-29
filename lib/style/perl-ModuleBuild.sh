# build_style=perl-ModuleBuild - Module::Build
. "$BPM_LIBDIR/style/perl-module.sh"

style_configure() { perl Build.PL installdirs=vendor ${configure_args:-}; }
style_build() { ./Build ${make_build_args:-}; }
style_check() { ./Build test ${make_check_args:-}; }
style_install() { ./Build install dest_dir="$DESTDIR" ${make_install_args:-}; perl_cleanup; }
