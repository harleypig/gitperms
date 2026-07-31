#!/usr/bin/env perl

# The SELinux half of a restore: the probe that decides whether to bother, and
# the restorecon pipe that does the work. Neither can be exercised through a
# real SELinux system here, so restorecon is stubbed on PATH and the probe is
# driven through the harness's view of the script's own lexicals.

use strict;
use warnings;

use lib 't/lib';

use Test::More;

use File::Path qw( mkpath );
use File::Spec ();
use File::Temp qw( tempdir );

use GitPerms::Test::Harness ();

my $pkg = GitPerms::Test::Harness::load();

my $tmp = tempdir( 'gitperms-selinux-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

#-------------------------------------------------------------------------------
# A stub restorecon that records the paths handed to it, or fails on demand.
# Returns the directory to put at the front of PATH.

sub stub_restorecon {

  my ( $name, $body ) = @_;

  my $bin = File::Spec->catdir( $tmp, $name );
  mkpath( $bin );

  my $stub = File::Spec->catfile( $bin, 'restorecon' );

  open my $fh, '>', $stub or die "create stub: $!";
  print { $fh } $body;
  close $fh or die "close stub: $!";

  chmod 0755, $stub;

  return $bin;

}

# Run restor_ctx with a given PATH, collecting whatever it warned.
sub restor_ctx_with {

  my ( $path, @files ) = @_;

  my @warnings;

  local $SIG{ __WARN__ } = sub { push @warnings, @_ };
  local $ENV{ PATH }     = $path;

  $pkg->can( 'restor_ctx' )->( \@files );

  return join q{}, @warnings;

}

#-------------------------------------------------------------------------------
# A pseudo-file standing in for /sys/fs/selinux/enforce.

sub enforce_file {

  my ( $name, $content ) = @_;

  my $path = File::Spec->catfile( $tmp, $name );

  open my $fh, '>', $path or die "create $path: $!";
  print { $fh } $content;
  close $fh or die "close $path: $!";

  return $path;

}

sub enforcing_with {

  my ( @paths ) = @_;

  no warnings 'once';  ## no critic ( TestingAndDebugging::ProhibitNoWarnings )
  local @GitPerms::Script::SELINUX_ENFORCE = @paths;

  return $pkg->can( 'selinux_enforcing' )->();

}

#-------------------------------------------------------------------------------

subtest 'the enforcing state is read from the first path that opens' => sub {

  # Issue #7. The probe was `qx/cat \/selinux\/enforce/` -- one path, which no
  # current distribution has, so it forked a cat that complained on every run
  # and always answered false.

  my $missing = File::Spec->catfile( $tmp, 'no-such-selinux' );

  ok !enforcing_with( $missing ), 'a path that does not exist answers no';
  ok !enforcing_with(),           'and so does having no path to try at all';

  ok enforcing_with( enforce_file( 'enforce-on', "1\n" ) ), 'a file holding 1 answers yes';

  # The reason chomping matters: "0\n" is a true string in perl, so an
  # SELinux system that was not enforcing would have read as one that was.
  ok !enforcing_with( enforce_file( 'enforce-off', "0\n" ) ), 'a file holding 0 answers no';

  ok enforcing_with( $missing, enforce_file( 'enforce-fallback', "1\n" ) ),
    'a missing first path falls through to the second';

};

subtest 'the restore is skipped entirely when SELinux is not enforcing' => sub {

  $pkg->can( 't_set_se_enforcing' )->( 0 );
  $pkg->can( 't_set_topdir' )->( $tmp );
  $pkg->can( 't_set_quiet' )->( undef );

  my $bin = stub_restorecon( 'never', "#!/bin/sh\nexit 1\n" );

  is restor_ctx_with( $bin, 'plain' ), q{}, 'nothing is run and nothing is said';

};

subtest 'the paths handed to restorecon are absolute' => sub {

  my $log = File::Spec->catfile( $tmp, 'seen' );

  my $bin = stub_restorecon( 'record', "#!/bin/sh\ncat > '$log'\n" );

  $pkg->can( 't_set_se_enforcing' )->( 1 );
  $pkg->can( 't_set_topdir' )->( $tmp );
  $pkg->can( 't_set_quiet' )->( 1 );

  my $warned = restor_ctx_with( $bin . ':' . $ENV{ PATH }, 'plain', 'sub/nested' );

  is $warned, q{}, 'a successful run says nothing under --quiet';

  open my $fh, '<', $log or die "read $log: $!";
  my @seen = <$fh>;
  close $fh;

  chomp @seen;

  is_deeply \@seen,
    [ File::Spec->catfile( $tmp, 'plain' ), File::Spec->catfile( $tmp, 'sub/nested' ) ],
    'each path is prefixed with the top level';

};

subtest 'a restorecon that cannot be run is reported' => sub {

  # `open FH, "|restorecon -f- -v" || warn ...` parsed as
  # open( FH, ( "|..." || warn ... ) ): || binds tighter than the list
  # operator, so open saw a truthy second argument and the warning was dead
  # code. A missing restorecon failed in total silence.

  my $empty = File::Spec->catdir( $tmp, 'empty' );
  mkpath( $empty );

  $pkg->can( 't_set_se_enforcing' )->( 1 );
  $pkg->can( 't_set_topdir' )->( $tmp );
  $pkg->can( 't_set_quiet' )->( 1 );

  like restor_ctx_with( $empty, 'plain' ), qr/Unable to execute restorecon/,
    'the failure to start restorecon is warned about';

};

subtest 'a restorecon that fails is reported' => sub {

  # The exit status of a command on the far end of a pipe turns up at close,
  # not at open, and close was not checked at all.

  my $bin = stub_restorecon( 'failing', "#!/bin/sh\ncat > /dev/null\nexit 3\n" );

  $pkg->can( 't_set_se_enforcing' )->( 1 );
  $pkg->can( 't_set_topdir' )->( $tmp );
  $pkg->can( 't_set_quiet' )->( 1 );

  like restor_ctx_with( $bin . ':' . $ENV{ PATH }, 'plain' ), qr/restorecon exited 3/,
    'the non-zero exit status is warned about';

};

done_testing();
