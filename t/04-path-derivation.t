#!/usr/bin/env perl

# GIT_DIR used to be guessed as dirname($0).'/../', which only ever worked for
# a copy installed at .git/hooks/handle_metadata in a normal clone. It now
# comes from `git rev-parse`, so the script has to work from a subdirectory, a
# linked worktree (where .git is a file), a copy on PATH, and under the
# relative GIT_DIR git exports to hooks -- and has to fail clearly outside a
# repository.
#
# These are black-box runs of the real script: the derivation happens at the
# top level, before any subroutine the harness could reach.

## no critic qw( ValuesAndExpressions::ProhibitLeadingZeros Lax::ProhibitLeadingZeros::ExceptChmod )

use strict;
use warnings;

use lib 't/lib';

use Test::More;

use Cwd       ();
use File::Copy ();
use File::Path qw( mkpath );
use File::Spec ();

use GitPerms::Test::Harness ();
use GitPerms::Test::Repo qw( git_available new_repo git_in write_file commit_all run_script note_for_head );

plan skip_all => 'git is not available'
  if !git_available();

#-------------------------------------------------------------------------------

sub fresh_repo {

  my $repo = new_repo();

  write_file( $repo, 'plain',        "content\n" );
  write_file( $repo, 'sub/nested',   "nested\n" );
  write_file( $repo, 'sub/deep/leaf', "leaf\n" );

  commit_all( $repo, 'initial' );

  return $repo;

}

# A run that reached the end printed "Done saving ..."; anything earlier died.
sub saved_ok {

  my ( $result, $label ) = @_;

  my $ok = $result->{ exit } == 0 && $result->{ stdout } =~ /Done saving/;

  diag "exit=$result->{exit}\nstdout: $result->{stdout}\nstderr: $result->{stderr}"
    if !$ok;

  return ok $ok, $label;

}

#-------------------------------------------------------------------------------

subtest 'from the top level of a normal clone' => sub {

  my $repo = fresh_repo();

  saved_ok run_script( $repo, ['--save'] ), 'saves from the work tree root';

  ok defined note_for_head( $repo ), 'a note was written';

};

subtest 'from a subdirectory' => sub {

  my $repo = fresh_repo();

  for my $rel ( 'sub', File::Spec->catdir( 'sub', 'deep' ) ) {

    my $cwd = File::Spec->catdir( $repo->{ root }, $rel );

    my $result = run_script( $repo, ['--save'], cwd => $cwd, env => { GIT_DIR => undef } );

    saved_ok $result, "saves when run from $rel";

    # The script chdirs to the top level, so the note must describe the whole
    # tree regardless of where it started.
    my $note = note_for_head( $repo );

    like $note, qr/"sub\/nested"/, "...and the note still covers the whole tree from $rel"
      if defined $note;

    git_in( $repo, 'notes', '--ref', 'gitperms', 'remove', 'HEAD' );

  }

};

subtest 'from a linked worktree, where .git is a file' => sub {

  my $repo = fresh_repo();

  my $linked = File::Spec->catdir( $repo->{ base }, 'linked' );

  my ( undef, $err, $status ) = git_in( $repo, 'worktree', 'add', '-b', 'side', $linked );

  plan skip_all => "git worktree add failed: $err"
    if $status != 0;

  ok -f File::Spec->catfile( $linked, '.git' ), 'the linked worktree has a .git file, not a directory';

  my $result = run_script( $repo, ['--save'], cwd => $linked, env => { GIT_DIR => undef } );

  saved_ok $result, 'saves from inside a linked worktree';

  my ( $note, undef, $note_status )
    = git_in( $repo, '-C', $linked, 'notes', '--ref', 'gitperms', 'show', 'HEAD' );

  is $note_status, 0, 'a note is attached to the worktree HEAD';
  like $note, qr/"plain"/, '...and it describes the worktree contents';

};

subtest 'under the relative GIT_DIR git exports to hooks' => sub {

  my $repo = fresh_repo();

  # This is exactly what a post-commit hook sees: cwd at the top level and
  # GIT_DIR set to the relative string ".git".
  my $result = run_script( $repo, ['--save'], env => { GIT_DIR => '.git' } );

  saved_ok $result, 'saves with a relative GIT_DIR of ".git"';

  ok defined note_for_head( $repo ), 'a note was written';

};

subtest 'invoked through PATH rather than by path' => sub {

  my $repo = fresh_repo();

  my $bin = File::Spec->catdir( $repo->{ base }, 'bin' );
  mkpath( $bin );

  my $installed = File::Spec->catfile( $bin, 'handle_metadata' );

  File::Copy::copy( GitPerms::Test::Harness::script_path(), $installed )
    or die "copy failed: $!";

  chmod 0755, $installed;

  # No repository above $bin at all, so the old dirname($0).'/../' guess had
  # nothing to find.
  my $result = run_script(
    $repo, ['--save'],
    exe       => $installed,
    bare_name => 1,
    env       => { PATH => $bin . ':' . ( $ENV{ PATH } || q{} ), GIT_DIR => undef },
  );

  saved_ok $result, 'saves when the script lives outside the repository';

  ok defined note_for_head( $repo ), 'a note was written';

};

subtest 'installed as .git/hooks/handle_metadata' => sub {

  my $repo = fresh_repo();

  my $hooks = File::Spec->catdir( $repo->{ root }, '.git', 'hooks' );
  mkpath( $hooks );

  my $installed = File::Spec->catfile( $hooks, 'handle_metadata' );

  File::Copy::copy( GitPerms::Test::Harness::script_path(), $installed )
    or die "copy failed: $!";

  chmod 0755, $installed;

  # The layout `setup` produces, and the only one the old derivation handled.
  my $result = run_script( $repo, ['--save'], exe => $installed, env => { GIT_DIR => undef } );

  saved_ok $result, 'saves from the installed hook location';

};

subtest 'outside any repository' => sub {

  my $repo = fresh_repo();

  # $repo->{base} contains the repository but is not itself one.
  my $result = run_script(
    $repo, ['--save'],
    cwd => $repo->{ base },
    env => { GIT_DIR => undef, GIT_WORK_TREE => undef },
  );

  isnt $result->{ exit }, 0, 'exits non-zero outside a repository';

  like $result->{ stderr }, qr/System error|Unable to get (?:git|top level) directory|not a git repository/i,
    'and says why';

  unlike $result->{ stdout }, qr/Done saving/, 'nothing was saved';

};

subtest 'from inside the git directory itself' => sub {

  # There is no work tree above .git, so there is nothing to operate on. What
  # matters is *how* the script declines.
  #
  #   $ENV{ GIT_WORK_TREE } = $topdir if length $topdir;
  #   chdir $topdir or die ...;
  #
  # The emptiness of $topdir is checked on the first line and not on the
  # second. Whether that matters depends on two independent behaviours:
  #
  #   * git <= 2.11 answers `rev-parse --show-toplevel` from inside .git with
  #     an empty string and exit 0; git >= 2.30 exits 128 with a fatal error.
  #   * perl <= 5.22 treats chdir('') as chdir() and moves to $HOME; perl
  #     >= 5.30 returns false, so the `or die` fires.
  #
  # On the old pairing the script does not stop: it changes to $HOME and then
  # resolves every tracked path relative to *that*, which under --set means
  # chmod/chown/utime against whatever happens to sit there. Both behaviours
  # are probed rather than assumed, so this reports honestly on any host.

  my $repo = fresh_repo();

  my $git_dir = File::Spec->catdir( $repo->{ root }, '.git' );

  my ( $toplevel, undef, $toplevel_status )
    = GitPerms::Test::Repo::capture_in( $git_dir, $repo->{ env }, 'git', 'rev-parse', '--show-toplevel' );

  my $git_answers_empty = $toplevel_status == 0 && $toplevel !~ /\S/;

  my $chdir_empty_succeeds = do {
    no warnings 'deprecated';  ## no critic ( TestingAndDebugging::ProhibitNoWarnings )
    my $cwd = Cwd::getcwd();
    my $ok  = chdir q{};
    chdir $cwd or die "unable to return to $cwd: $!";
    $ok ? 1 : 0;
  };

  diag sprintf 'git returns an empty toplevel from inside .git: %s; chdir("") succeeds: %s',
    ( $git_answers_empty ? 'yes' : 'no' ), ( $chdir_empty_succeeds ? 'yes' : 'no' );

  # Save normally first, so there is a note for the --set below to act on.
  run_script( $repo, ['--save'] );

  # A decoy at the same relative path as a tracked file, sitting in $HOME --
  # exactly where an unguarded chdir would land. Its content matches the
  # tracked blob byte for byte, which matters: the ignore list is built from
  # `git status` run in whatever directory the script ended up in, so a decoy
  # with *different* content is reported as modified and skipped by accident.
  # Only an identical one reaches the restore. The tracked 'plain' is 0644, so
  # a stray restore would change this from 0600 to 0644.
  my $decoy = File::Spec->catfile( $repo->{ home }, 'plain' );

  open my $fh, '>', $decoy or die "create decoy: $!";
  print { $fh } "content\n";
  close $fh;

  chmod 0600, $decoy;

  my $result = run_script(
    $repo, ['--set'],
    cwd => $git_dir,
    env => { GIT_DIR => undef },
  );

  my $vulnerable = $git_answers_empty && $chdir_empty_succeeds;

  SKIP: {

    skip 'this git reports a proper error instead of an empty toplevel', 2
      if $git_answers_empty;

    isnt $result->{ exit }, 0, 'exits non-zero from inside .git';

    like $result->{ stderr }, qr/must be run in a work tree/,
      'git\'s own explanation reaches the user';

  }

  TODO: {

    local $TODO = 'chdir $topdir is not guarded by the length check on the line above'
      if $vulnerable;

    unlike $result->{ stdout }, qr/Done setting/,
      'the script does not report success after failing to find a work tree';

  }

  TODO: {

    local $TODO = 'an unguarded chdir("") lands in $HOME and restores tracked paths there'
      if $vulnerable;

    is sprintf( '%04o', ( stat $decoy )[2] & 07777 ), '0600',
      'a file in $HOME at a tracked path is left alone';

  }

};

subtest 'a submodule has its own gitdir pointer' => sub {

  my $outer = fresh_repo();
  my $inner = fresh_repo();

  # file:// keeps this off the network and away from protocol.file.allow for
  # the add itself; older git needs the flag, newer git needs it too.
  my ( undef, $err, $status ) = git_in(
    $outer,
    '-c', 'protocol.file.allow=always',
    'submodule', 'add', '--quiet', $inner->{ root }, 'modules/inner',
  );

  plan skip_all => "git submodule add failed: $err"
    if $status != 0;

  commit_all( $outer, 'add submodule' );

  my $path = File::Spec->catdir( $outer->{ root }, 'modules', 'inner' );

  ok -f File::Spec->catfile( $path, '.git' ), 'the submodule has a .git file pointing at the outer gitdir';

  my $result = run_script( $outer, ['--save'], cwd => $path, env => { GIT_DIR => undef } );

  saved_ok $result, 'saves from inside a submodule';

  my ( $note, undef, $note_status )
    = git_in( $outer, '-C', $path, 'notes', '--ref', 'gitperms', 'show', 'HEAD' );

  is $note_status, 0, 'the note is attached to the submodule HEAD, not the superproject';

};

done_testing();
