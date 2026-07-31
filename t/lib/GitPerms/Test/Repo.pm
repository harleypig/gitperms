package GitPerms::Test::Repo;

# Throwaway git repositories and a black-box runner for handle_metadata.
#
# Every repository is created with the ambient git configuration neutralised
# (GIT_CONFIG_NOSYSTEM, HOME and XDG_CONFIG_HOME pointed at the sandbox) so a
# developer's ~/.gitconfig -- core.quotePath, commit.gpgsign, a hook template
# -- cannot change what the tests observe.

use strict;
use warnings;

use Cwd            ();
use Exporter       'import';
use File::Path     qw( mkpath );
use File::Spec     ();
use File::Temp     qw( tempdir );
use GitPerms::Test::Harness ();
use POSIX          ();

our @EXPORT_OK = qw(
  capture
  capture_in
  git_available
  new_repo
  git_in
  commit_all
  write_file
  run_script
  run_with_timeout
  note_for_head
);

#-------------------------------------------------------------------------------
# Run a command with stdout and stderr captured separately. Deliberately a
# reimplementation rather than a call into the script's run_cmd: a helper that
# shares the machinery under test cannot be trusted to report on it.

sub _capture {

  my ( $cwd, $env, @cmd ) = @_;

  my $out_file = File::Temp->new( TEMPLATE => 'gpout-XXXXXX', TMPDIR => 1 );
  my $err_file = File::Temp->new( TEMPLATE => 'gperr-XXXXXX', TMPDIR => 1 );

  my $pid = fork;

  die "fork failed: $!\n"
    if !defined $pid;

  if ( !$pid ) {

    ## no critic ( InputOutput::ProhibitBarewordFileHandles InputOutput::RequireCheckedOpen )
    open STDOUT, '>', $out_file->filename or POSIX::_exit( 127 );
    open STDERR, '>', $err_file->filename or POSIX::_exit( 127 );

    if ( defined $cwd ) {
      chdir $cwd or POSIX::_exit( 127 );
    }

    # Not localised on purpose: this is the forked child, and the very next
    # statement replaces it with exec.
    ## no critic ( Variables::RequireLocalizedPunctuationVars )
    for my $name ( keys %$env ) {

      if ( defined $env->{ $name } ) { $ENV{ $name } = $env->{ $name } }
      else                           { delete $ENV{ $name } }

    }
    ## use critic

    exec { $cmd[0] } @cmd or POSIX::_exit( 127 );

  }

  waitpid $pid, 0;

  my $status = $?;

  return ( _slurp( $out_file->filename ), _slurp( $err_file->filename ), $status );

}

sub _slurp {

  my ( $path ) = @_;

  open my $fh, '<', $path
    or return q{};

  local $/;
  my $content = <$fh>;

  close $fh;

  return defined $content ? $content : q{};

}

#-------------------------------------------------------------------------------

# Run a command outside any repository sandbox. Returns ( $stdout, $stderr, $? ).

sub capture {

  my ( @cmd ) = @_;

  return _capture( undef, {}, @cmd );

}

#-------------------------------------------------------------------------------
# As capture(), from a given directory and under a given environment.

sub capture_in {

  my ( $cwd, $env, @cmd ) = @_;

  return _capture( $cwd, $env || {}, @cmd );

}

#-------------------------------------------------------------------------------

sub git_available {

  my ( undef, undef, $status ) = _capture( undef, {}, 'git', '--version' );

  return $status == 0;

}

#-------------------------------------------------------------------------------
# The environment every git invocation in these tests runs under.

sub _sandbox_env {

  my ( $home ) = @_;

  return {
    HOME                 => $home,
    XDG_CONFIG_HOME      => File::Spec->catdir( $home, 'xdg' ),
    GIT_CONFIG_NOSYSTEM  => '1',
    GIT_AUTHOR_NAME      => 'gitperms tests',
    GIT_AUTHOR_EMAIL     => 'tests@example.invalid',
    GIT_COMMITTER_NAME   => 'gitperms tests',
    GIT_COMMITTER_EMAIL  => 'tests@example.invalid',
    GIT_AUTHOR_DATE      => '2020-01-01T00:00:00 +0000',
    GIT_COMMITTER_DATE   => '2020-01-01T00:00:00 +0000',
    GIT_DIR              => undef,
    GIT_WORK_TREE        => undef,
  };

}

#-------------------------------------------------------------------------------
# Create an initialised repository. Returns a hashref describing it:
#   { root => <work tree>, home => <sandbox HOME>, env => <env hashref> }

sub new_repo {

  my %opt = @_;

  my $base = tempdir( 'gitperms-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
  my $home = File::Spec->catdir( $base, 'home' );
  my $root = File::Spec->catdir( $base, ( $opt{ name } || 'repo' ) );

  mkpath( $_ ) for $home, $root;

  my $repo = { base => $base, root => $root, home => $home, env => _sandbox_env( $home ) };

  git_in( $repo, 'init', '--quiet', '.' );

  # A default branch name is only a warning, but pinning it keeps output clean
  # across git versions.
  git_in( $repo, 'symbolic-ref', 'HEAD', 'refs/heads/master' );

  return $repo;

}

#-------------------------------------------------------------------------------

sub git_in {

  my ( $repo, @args ) = @_;

  return _capture( $repo->{ root }, $repo->{ env }, 'git', @args );

}

#-------------------------------------------------------------------------------

sub write_file {

  my ( $repo, $relative, $content ) = @_;

  my $path = File::Spec->catfile( $repo->{ root }, $relative );

  my ( undef, $dir ) = ( File::Spec->splitpath( $path ) )[ 0, 1 ];
  mkpath( $dir ) if length $dir && !-d $dir;

  open my $fh, '>', $path
    or die "Unable to write $path: $!\n";

  print { $fh } defined $content ? $content : q{};

  close $fh
    or die "Unable to close $path: $!\n";

  return $path;

}

#-------------------------------------------------------------------------------

sub commit_all {

  my ( $repo, $message ) = @_;

  git_in( $repo, 'add', '--all', '.' );

  return git_in( $repo, 'commit', '--quiet', '--allow-empty', '-m', $message || 'test' );

}

#-------------------------------------------------------------------------------
# Black-box invocation of handle_metadata. %opt keys:
#   cwd  - directory to run from (defaults to the work tree)
#   env  - extra environment overrides (undef value unsets)
#   exe  - path to the script (defaults to the one under test)

sub run_script {

  my ( $repo, $args, %opt ) = @_;

  my %env = %{ $repo->{ env } };
  $env{ $_ } = $opt{ env }{ $_ } for keys %{ $opt{ env } || {} };

  my $exe = $opt{ exe } || GitPerms::Test::Harness::script_path();
  my $cwd = $opt{ cwd } || $repo->{ root };

  my @cmd = $opt{ bare_name } ? ( $exe ) : ( $^X, $exe );

  my ( $out, $err, $status ) = _capture( $cwd, \%env, @cmd, @{ $args || [] } );

  return {
    stdout => $out,
    stderr => $err,
    status => $status,
    exit   => $status >> 8,
    signal => $status & 127,
  };

}

#-------------------------------------------------------------------------------
# The raw gitperms note attached to HEAD, or undef when there is none.

sub note_for_head {

  my ( $repo ) = @_;

  my ( $out, undef, $status ) = git_in( $repo, 'notes', '--ref', 'gitperms', 'show', 'HEAD' );

  return if $status != 0;

  return $out;

}

#-------------------------------------------------------------------------------
# Run $code in a child process under a wall-clock limit, so a regression that
# reintroduces a deadlock fails the test instead of hanging the suite.
#
# Returns ( $timed_out, $exit_code, $captured ) where $captured is whatever the
# child printed on stdout.

sub run_with_timeout {

  my ( $seconds, $code ) = @_;

  my $tmp = File::Temp->new( TEMPLATE => 'gptimeout-XXXXXX', TMPDIR => 1 );

  my $pid = fork;

  die "fork failed: $!\n"
    if !defined $pid;

  if ( !$pid ) {

    ## no critic ( InputOutput::ProhibitBarewordFileHandles InputOutput::RequireCheckedOpen )
    open STDOUT, '>', $tmp->filename or POSIX::_exit( 127 );

    my $rc = eval { $code->(); 0 };

    POSIX::_exit( defined $rc ? $rc : 1 );

  }

  my $deadline = time + $seconds;
  my $reaped   = 0;

  while ( time < $deadline ) {

    $reaped = waitpid $pid, POSIX::WNOHANG();

    last if $reaped == $pid;

    select undef, undef, undef, 0.05;  ## no critic ( BuiltinFunctions::ProhibitSleepViaSelect )

  }

  if ( $reaped != $pid ) {

    kill 'KILL', $pid;
    waitpid $pid, 0;

    return ( 1, undef, _slurp( $tmp->filename ) );

  }

  return ( 0, $? >> 8, _slurp( $tmp->filename ) );

}

1;
