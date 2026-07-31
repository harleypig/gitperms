#!/usr/bin/env perl

# The zero-dependency invariant, and that the script and installer are at
# least syntactically sound. Everything gitperms uses must ship with perl
# itself; a CPAN module creeping back into the import list is the single
# regression that would undo the whole modernisation.

use strict;
use warnings;

use lib 't/lib';

use Test::More;

use Config     ();
use File::Spec ();

use GitPerms::Test::Harness ();
use GitPerms::Test::Repo qw( capture );

my $script = GitPerms::Test::Harness::script_path();

ok -e $script, 'handle_metadata is where the harness expects it';
ok -x $script, 'handle_metadata is executable';

#-------------------------------------------------------------------------------

{
  my ( undef, $err, $status ) = capture( $^X, '-c', $script );

  is $status, 0, 'handle_metadata compiles'
    or diag $err;

  like $err, qr/syntax OK/, 'perl reports syntax OK';
}

{
  my $setup = File::Spec->catfile( ( File::Spec->splitpath( $script ) )[1], 'setup' );

  SKIP: {

    skip 'setup is not present', 1
      if !-e $setup;

    my ( undef, $err, $status ) = capture( '/bin/sh', '-n', $setup );

    is $status, 0, 'setup is valid POSIX shell'
      or diag $err;

  }
}

#-------------------------------------------------------------------------------
# Every module the script imports must be core for the perl running the tests.

{
  open my $fh, '<', $script or die "read $script: $!";

  my @modules;
  my $in_pod = 0;

  while ( my $line = <$fh> ) {

    $in_pod = 1 if $line =~ /^=\w/;
    $in_pod = 0 if $line =~ /^=cut/;

    next if $in_pod;
    next if $line =~ /^\s*#/;

    # 'use 5.014', 'use strict', 'use constant' are pragmas, not dependencies.
    next if $line =~ /^\s*use\s+v?[\d.]+\s*;/;

    push @modules, $1
      if $line =~ /^\s*(?:use|require)\s+([A-Z][\w:]*)/;

  }

  close $fh;

  my %pragma = map { $_ => 1 } qw( Config );

  my @checked = grep { !$pragma{ $_ } } @modules;

  ok scalar @checked, 'the script imports at least one module';

  my $lib = $Config::Config{ privlib };
  my $arch = $Config::Config{ archlib };

  for my $module ( @checked ) {

    my $relative = File::Spec->catfile( split /::/, $module ) . '.pm';

    my $found;

    for my $root ( $lib, $arch ) {

      my $candidate = File::Spec->catfile( $root, $relative );

      next if !-e $candidate;

      $found = $candidate;
      last;

    }

    ok defined $found, "$module ships with perl (found under privlib/archlib)"
      or diag "$module was not found in $lib or $arch -- it is not a core module";

  }
}

#-------------------------------------------------------------------------------
# The harness itself: if its split points stop matching, every unit test in the
# suite silently loses its subject, so failing loudly here matters.

{
  my $pkg = eval { GitPerms::Test::Harness::load() };

  ok defined $pkg, 'the harness compiles handle_metadata into a test package'
    or diag $@;

  SKIP: {

    skip 'harness did not load', 1
      if !defined $pkg;

    my @expected = qw(
      run_cmd get_git_dir get_toplevel
      get_metadata_from_system set_metadata_in_system
      set_note get_note
      chown_file chmod_file touch_file extnd_attr restor_ctx
      make_special_file get_file_flags set_file_flags read_flags
    );

    my @missing = grep { !$pkg->can( $_ ) } @expected;

    is_deeply \@missing, [], 'every expected subroutine is reachable through the harness';

  }
}

done_testing();
