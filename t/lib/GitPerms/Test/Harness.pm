package GitPerms::Test::Harness;

# handle_metadata is a script, not a module: its top level derives the git
# directory, parses @ARGV, and exits. Loading it with require/do would run all
# of that, so the subroutines cannot be reached that way.
#
# This harness compiles the script's *own source* -- not a copy of it -- into
# a separate package, minus the top-level body. It takes the text before the
# first executable statement (the pragmas, imports, and constants) and the
# text after the section separator (every subroutine), declares the file-scope
# lexicals the subroutines close over, and appends accessors for them.
#
# The two split points are structural, and both are asserted: if the script is
# restructured so a marker no longer matches, load() dies naming the marker
# instead of silently testing nothing.

use strict;
use warnings;

use File::Basename qw( dirname );
use File::Spec     ();

our $PACKAGE = 'GitPerms::Script';

my $loaded;

#-------------------------------------------------------------------------------
# Absolute path to the handle_metadata under test. GITPERMS_SCRIPT overrides it
# so a container tier can point at a mounted copy.

sub script_path {

  return $ENV{ GITPERMS_SCRIPT }
    if defined $ENV{ GITPERMS_SCRIPT } && length $ENV{ GITPERMS_SCRIPT };

  # .../t/lib/GitPerms/Test/Harness.pm -> .../handle_metadata
  my $here = dirname( __FILE__ );
  my $root = File::Spec->catdir( $here, ( File::Spec->updir ) x 4 );

  return File::Spec->rel2abs( File::Spec->catfile( $root, 'handle_metadata' ) );

}

#-------------------------------------------------------------------------------

sub script_source {

  my $path = script_path();

  open my $fh, '<', $path
    or die "Unable to read $path: $!\n";

  local $/;
  my $src = <$fh>;

  close $fh;

  return $src;

}

#-------------------------------------------------------------------------------
# The lexicals the subroutines share with the script's top level. Declaring
# them inside the same eval is what lets the subroutines compile, and the
# generated accessors are the seam tests drive them through.

my @SCALARS = qw( create_on_missing force quiet topdir se_enforcing );
my @ARRAYS  = qw( files );
my @HASHES  = qw( ignore metadata );

# Accessors are prefixed so they can never collide with a script subroutine
# (the script already has a get_git_dir, for instance).
my $PREFIX = 't_';

sub _declarations {

  my @lines = (
    ( map {"my \$$_;"} @SCALARS ),
    ( map {"my \@$_;"} @ARRAYS ),
    ( map {"my \%$_;"} @HASHES ),
  );

  return join "\n", @lines;

}

sub _accessors {

  my @lines;

  for my $name ( @SCALARS ) {
    push @lines, "sub ${PREFIX}set_$name { \$$name = \$_[0]; return }";
    push @lines, "sub ${PREFIX}get_$name { return \$$name }";
  }

  for my $name ( @ARRAYS ) {
    push @lines, "sub ${PREFIX}set_$name { \@$name = \@_; return }";
    push @lines, "sub ${PREFIX}get_$name { return \\\@$name }";
  }

  for my $name ( @HASHES ) {
    push @lines, "sub ${PREFIX}set_$name { \%$name = \%{ \$_[0] }; return }";
    push @lines, "sub ${PREFIX}get_$name { return \\\%$name }";
  }

  return join "\n", @lines;

}

#-------------------------------------------------------------------------------
# Compile the script's prelude + subroutines into $PACKAGE. Idempotent.

sub load {

  return $PACKAGE if $loaded;

  my $path = script_path();
  my $src  = script_source();

  my ( $prelude ) = $src =~ m{\A (.*?) ^my \s+ \$git_dir \s* = \s* get_git_dir}msx;

  die "Harness out of date: $path no longer starts its top-level body with "
    . "'my \$git_dir = get_git_dir()'. Update GitPerms::Test::Harness.\n"
    if !defined $prelude;

  my ( $subs ) = $src =~ m{^ \#{20,} \s*? $ (.*) \z}msx;

  die "Harness out of date: $path no longer separates its subroutines with a "
    . "run of 20+ '#'. Update GitPerms::Test::Harness.\n"
    if !defined $subs;

  # The script's own 'use strict/warnings' come along inside $prelude.
  my $code = join "\n",
    "package $PACKAGE;",
    $prelude,
    _declarations(),
    $subs,
    _accessors(),
    '1;';

  my $ok = eval $code;  ## no critic ( BuiltinFunctions::ProhibitStringyEval )

  die "Unable to compile $path into $PACKAGE: $@\n"
    if !$ok;

  $loaded = 1;

  return $PACKAGE;

}

#-------------------------------------------------------------------------------
# Convenience: call a subroutine (or read a constant) in the loaded package.

sub call {

  my ( $name, @args ) = @_;

  load();

  my $code = $PACKAGE->can( $name )
    or die "$PACKAGE has no sub '$name'\n";

  return $code->( @args );

}

1;
