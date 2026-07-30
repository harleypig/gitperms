#!/usr/bin/env perl

# What get_metadata_from_system records, and what set_metadata_in_system does
# with it. Only the unprivileged half is covered here: chown to another uid,
# device nodes, and hardlink reconstruction need tier 3.

## no critic qw( ValuesAndExpressions::ProhibitLeadingZeros Lax::ProhibitLeadingZeros::ExceptChmod )

use strict;
use warnings;

use lib 't/lib';

use Test::More;

use File::Spec ();
use JSON::PP   ();

use GitPerms::Test::Repo qw( git_available new_repo git_in write_file commit_all run_script note_for_head );

plan skip_all => 'git is not available'
  if !git_available();

#-------------------------------------------------------------------------------
# Collection, driven through the script so the real ls-tree parsing runs.

sub note_hash {

  my ( $repo ) = @_;

  my $raw = note_for_head( $repo )
    or return;

  return JSON::PP->new->utf8->decode( $raw );

}

# Flatten a note into { filename => inode-record }.
sub by_name {

  my ( $note ) = @_;

  my %by_name;

  for my $sha ( keys %$note ) {

    for my $ino ( keys %{ $note->{ $sha } } ) {

      my $record = $note->{ $sha }{ $ino };

      $by_name{ $_ } = $record for @{ $record->{ name } || [] };

    }
  }

  return \%by_name;

}

#-------------------------------------------------------------------------------

subtest 'file types are classified' => sub {

  my $repo = new_repo();

  write_file( $repo, 'regular', "content\n" );
  write_file( $repo, 'adir/inside', "nested\n" );

  symlink 'regular', File::Spec->catfile( $repo->{ root }, 'alink' )
    or plan skip_all => "symlink unsupported: $!";

  chmod 0751, File::Spec->catfile( $repo->{ root }, 'regular' );

  commit_all( $repo, 'initial' );

  my $result = run_script( $repo, ['--save'] );
  is $result->{ exit }, 0, '--save succeeded';

  my $by_name = by_name( note_hash( $repo ) );

  is $by_name->{ regular }{ type }, 'RF',  'a regular file is RF';
  is $by_name->{ adir }{ type },    'DIR', 'a directory is DIR';
  is $by_name->{ alink }{ type },   'SL',  'a symlink is SL';

  is $by_name->{ regular }{ chmod }, '0751', 'the mode is recorded as a zero-padded octal string';

  ok exists $by_name->{ regular }{ $_ }, "$_ is recorded"
    for qw( dev ino mode nlink uid gid rdev size atime mtime ctime blksize blocks );

  is $by_name->{ regular }{ uid }, $<, 'uid is the running user';

};

subtest 'a symlink is left alone on restore' => sub {

  # Issue #5. The link itself has no meaningful mode, and chmod would follow it
  # to the target, so set_metadata_in_system skips type SL entirely.
  my $repo = new_repo();

  write_file( $repo, 'target', "content\n" );

  symlink 'target', File::Spec->catfile( $repo->{ root }, 'alink' )
    or plan skip_all => "symlink unsupported: $!";

  chmod 0644, File::Spec->catfile( $repo->{ root }, 'target' );

  commit_all( $repo, 'initial' );

  run_script( $repo, ['--save'] );

  # Change the target's mode, then restore. The note's SL entry must not be
  # what puts it back, and must not clobber it either.
  chmod 0600, File::Spec->catfile( $repo->{ root }, 'target' );

  my $result = run_script( $repo, ['--set'] );
  is $result->{ exit }, 0, '--set succeeded';

  my $mode = ( stat File::Spec->catfile( $repo->{ root }, 'target' ) )[2] & 07777;

  is sprintf( '%04o', $mode ), '0644', 'the target is restored through its own entry';

  ok -l File::Spec->catfile( $repo->{ root }, 'alink' ), 'the symlink is still a symlink';

};

subtest 'mode and timestamps round-trip' => sub {

  my $repo = new_repo();

  write_file( $repo, 'a', "a\n" );
  write_file( $repo, 'b', "b\n" );

  my $path_a = File::Spec->catfile( $repo->{ root }, 'a' );
  my $path_b = File::Spec->catfile( $repo->{ root }, 'b' );

  commit_all( $repo, 'initial' );

  # Set the metadata *after* committing: git reads every file it commits,
  # which moves atime, so anything set beforehand is not what --save records.
  #
  # Both modes stay non-executable. Crossing the executable bit makes git
  # report the file as modified, which puts it on the ignore list -- see the
  # dedicated subtest below.
  chmod 0640, $path_a;
  chmod 0644, $path_b;

  my $mtime = 1_400_000_000;

  utime 1_500_000_000, $mtime, $path_a or die "utime: $!";

  run_script( $repo, ['--save'] );

  # Restore is measured against what the note actually holds, not against what
  # the file had before --save ran. The two differ for atime; see the next
  # subtest.
  my $recorded = by_name( note_hash( $repo ) )->{ a };

  # Disturb everything the note recorded.
  chmod 0600, $path_a;
  chmod 0600, $path_b;
  utime time, time, $path_a;

  my $result = run_script( $repo, ['--set'] );
  is $result->{ exit }, 0, '--set succeeded';

  is sprintf( '%04o', ( stat $path_a )[2] & 07777 ), '0640', 'mode restored for a';
  is sprintf( '%04o', ( stat $path_b )[2] & 07777 ), '0644', 'mode restored for b';

  is $recorded->{ mtime }, $mtime, 'the note recorded the mtime that was set';

  is( ( stat $path_a )[9], $recorded->{ mtime }, 'mtime restored from the note' );
  is( ( stat $path_a )[8], $recorded->{ atime }, 'atime restored from the note' );

};

subtest 'the recorded atime is the moment gitperms ran, not the file\'s atime' => sub {

  # Before collecting anything, the script runs
  #     git status --porcelain --untracked-files=no
  # to build its ignore list. Whenever git's stat cache is stale for a file it
  # re-reads that file to decide whether it really changed, which updates the
  # file's atime -- so by the time lstat runs, the original atime is gone.
  #
  # The restore side is faithful (the subtest above proves utime applies what
  # the note holds); it is the *captured* value that is not the file's real
  # atime. Pre-existing, not introduced by the modernisation.

  my $repo = new_repo();

  write_file( $repo, 'a', "a\n" );
  commit_all( $repo, 'initial' );

  my $path = File::Spec->catfile( $repo->{ root }, 'a' );

  my $wanted = 1_500_000_000;

  utime $wanted, 1_400_000_000, $path or die "utime: $!";

  is( ( stat $path )[8], $wanted, 'the file has the atime we set' );

  my $started = time;

  run_script( $repo, ['--save'] );

  my $recorded = by_name( note_hash( $repo ) )->{ a };

  isnt $recorded->{ atime }, $wanted, 'the note does NOT hold the atime the file had';

  cmp_ok $recorded->{ atime }, '>=', $started,
    'it holds the time gitperms itself read the file';

  is $recorded->{ mtime }, 1_400_000_000, 'mtime is unaffected and recorded correctly';

};

subtest 'drift across the executable bit is NOT restored' => sub {

  # git tracks the executable bit, so losing it makes `git status --porcelain`
  # report " M <file>". That lands the file on the ignore list, and --set
  # skips it -- which is exactly the drift gitperms exists to repair.
  #
  # Recorded as current behaviour. Whether the ignore list should exclude a
  # mode-only difference is a design question, not a test bug.
  my $repo = new_repo();

  write_file( $repo, 'script', "#!/bin/sh\n" );

  my $path = File::Spec->catfile( $repo->{ root }, 'script' );

  chmod 0755, $path;

  commit_all( $repo, 'initial' );

  run_script( $repo, ['--save'] );

  my $by_name = by_name( note_hash( $repo ) );
  is $by_name->{ script }{ chmod }, '0755', 'the executable mode was saved';

  chmod 0644, $path;

  my ( $porcelain ) = git_in( $repo, 'status', '--porcelain', '--untracked-files=no' );
  like $porcelain, qr/^ M script$/m, 'git reports the mode change as an unstaged modification';

  my $result = run_script( $repo, ['--set'] );
  is $result->{ exit }, 0, '--set exits 0';

  is sprintf( '%04o', ( stat $path )[2] & 07777 ), '0644',
    'the executable bit is NOT restored: the file is on the ignore list';

};

subtest 'a tracked file that has been deleted is skipped, not fatal' => sub {

  my $repo = new_repo();

  write_file( $repo, 'keep',   "keep\n" );
  write_file( $repo, 'vanish', "vanish\n" );

  commit_all( $repo, 'initial' );

  run_script( $repo, ['--save'] );

  unlink File::Spec->catfile( $repo->{ root }, 'vanish' ) or die "unlink: $!";

  my $result = run_script( $repo, ['--set'] );

  is $result->{ exit }, 0, '--set still exits 0';
  like $result->{ stdout }, qr/Done setting/, 'the run completes';

  # A deletion is reported by git as " D vanish", which the ignore list picks
  # up, so the file never reaches the "does not exist" branch.
  unlike $result->{ stderr }, qr/vanish does not exist/,
    'the ignore list catches the deletion before the existence check';

  ok -e File::Spec->catfile( $repo->{ root }, 'keep' ), 'the surviving file is untouched';

};

subtest 'a file missing at save time is skipped' => sub {

  my $repo = new_repo();

  write_file( $repo, 'present', "present\n" );
  write_file( $repo, 'removed', "removed\n" );

  commit_all( $repo, 'initial' );

  unlink File::Spec->catfile( $repo->{ root }, 'removed' ) or die "unlink: $!";

  my $result = run_script( $repo, ['--save'] );

  is $result->{ exit }, 0, '--save still exits 0';

  my $by_name = by_name( note_hash( $repo ) );

  ok exists $by_name->{ present }, 'the readable file is recorded';
  ok !exists $by_name->{ removed }, 'the missing file is not recorded';

  # Again the ignore list, not the lstat failure, is what excludes it -- so
  # the "Problem getting stat" warning never appears for this case.
  unlike $result->{ stderr }, qr/Problem getting stat on removed/,
    'the deletion is filtered by the ignore list, not by a failed lstat';

};

subtest 'a file that is unreadable but present still warns' => sub {

  # The lstat-failure branch is reachable when the path exists in HEAD but
  # cannot be stat'ed for a reason git does not report as a modification: a
  # directory component with no search permission.
  plan skip_all => 'running as root, which ignores directory permissions'
    if $< == 0;

  my $repo = new_repo();

  write_file( $repo, 'locked/inside', "inside\n" );

  commit_all( $repo, 'initial' );

  my $dir = File::Spec->catdir( $repo->{ root }, 'locked' );

  chmod 0000, $dir or die "chmod: $!";

  my $result = run_script( $repo, ['--save'] );

  chmod 0755, $dir;

  is $result->{ exit }, 0, '--save still exits 0';

  like $result->{ stderr }, qr{Problem getting stat on locked/inside},
    'the unreadable path is named on stderr';

};

subtest 'hardlinked files are classified' => sub {

  my $repo = new_repo();

  write_file( $repo, 'original', "shared\n" );

  link File::Spec->catfile( $repo->{ root }, 'original' ),
    File::Spec->catfile( $repo->{ root }, 'hardlink' )
    or plan skip_all => "hardlinks unsupported: $!";

  commit_all( $repo, 'initial' );

  run_script( $repo, ['--save'] );

  my $note = note_hash( $repo );

  # Both names share one inode, so they share one record.
  my ( $record ) = map { values %$_ } values %$note;

  is scalar @{ $record->{ name } }, 2, 'both names are recorded against the single inode';
  is $record->{ nlink }, 2, 'nlink is recorded as 2';

  is $record->{ type }, 'HL', 'the pair is classified as HL';

};

done_testing();
