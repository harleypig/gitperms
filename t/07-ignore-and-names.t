#!/usr/bin/env perl

# Two things the script derives from git's own output, both of which decide
# whether a file is handled at all:
#
#   * the ignore list, parsed out of `git status --porcelain`
#   * the file list, parsed out of `git ls-tree -r -t HEAD`
#
# Several of these tests record behaviour that is wrong but current. They are
# marked, and say what the right answer would be, so Phase 2 can flip them.

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

sub note_names {

  my ( $repo ) = @_;

  my $raw = note_for_head( $repo )
    or return {};

  my $note = JSON::PP->new->utf8->decode( $raw );

  my %seen;

  for my $sha ( keys %$note ) {

    for my $ino ( keys %{ $note->{ $sha } } ) {

      $seen{ $_ } = 1 for @{ $note->{ $sha }{ $ino }{ name } || [] };

    }
  }

  return \%seen;

}

#-------------------------------------------------------------------------------

subtest 'the ignore list excludes unstaged modifications' => sub {

  my $repo = new_repo();

  write_file( $repo, 'clean',    "clean\n" );
  write_file( $repo, 'modified', "before\n" );

  commit_all( $repo, 'initial' );

  write_file( $repo, 'modified', "after\n" );

  my ( $porcelain ) = git_in( $repo, 'status', '--porcelain', '--untracked-files=no' );
  like $porcelain, qr/^ M modified$/m, 'git reports an unstaged modification as " M"';

  run_script( $repo, ['--save'] );

  my $names = note_names( $repo );

  ok $names->{ clean },     'the clean file is recorded';
  ok !$names->{ modified }, 'the unstaged modification is excluded, as intended';

};

subtest 'the ignore list MISSES staged changes' => sub {

  # `git status --porcelain` puts the staged status in column 1 and the
  # unstaged status in column 2, so a staged-only change is "M  file" -- and
  # the ignore regex /^\s\S\s/ requires a *space* in column 1. Staged changes
  # therefore never reach the ignore list, and gitperms happily records or
  # restores metadata for a file whose content is mid-edit.

  my $repo = new_repo();

  write_file( $repo, 'staged', "before\n" );

  commit_all( $repo, 'initial' );

  write_file( $repo, 'staged', "after\n" );
  git_in( $repo, 'add', 'staged' );

  my ( $porcelain ) = git_in( $repo, 'status', '--porcelain', '--untracked-files=no' );
  like $porcelain, qr/^M  staged$/m, 'git reports a staged-only change as "M " (no leading space)';

  run_script( $repo, ['--save'] );

  my $names = note_names( $repo );

  ok $names->{ staged },
    'current behaviour: a staged-only change is NOT excluded from the note';

  TODO: {
    local $TODO = 'the ignore regex /^\s\S\s/ only matches unstaged changes';

    ok !$names->{ staged }, 'a staged change should be excluded like an unstaged one';
  }

};

subtest 'the ignore list also excludes deletions and both-column changes' => sub {

  my $repo = new_repo();

  write_file( $repo, 'keep',    "keep\n" );
  write_file( $repo, 'deleted', "deleted\n" );
  write_file( $repo, 'both',    "both\n" );

  commit_all( $repo, 'initial' );

  unlink File::Spec->catfile( $repo->{ root }, 'deleted' ) or die "unlink: $!";

  write_file( $repo, 'both', "staged\n" );
  git_in( $repo, 'add', 'both' );
  write_file( $repo, 'both', "and unstaged\n" );

  my ( $porcelain ) = git_in( $repo, 'status', '--porcelain', '--untracked-files=no' );

  like $porcelain, qr/^ D deleted$/m, 'a deletion is reported as " D"';
  like $porcelain, qr/^MM both$/m,    'a staged-and-unstaged change is reported as "MM"';

  run_script( $repo, ['--save'] );

  my $names = note_names( $repo );

  ok $names->{ keep },     'the clean file is recorded';
  ok !$names->{ deleted }, 'the deleted file is excluded';

  ok $names->{ both },
    'current behaviour: "MM" is NOT excluded either -- column 1 is not a space';

};

subtest 'a file whose name git would C-quote is still handled' => sub {

  # Issue #18. `git ls-tree` C-quotes any path containing a double quote, a
  # backslash, a control character, or (unless core.quotePath is false) a byte
  # above 0x7f. The script never unquoted, so lstat was handed the *quoted*
  # string, failed, and the file was skipped with a warning -- its metadata
  # never saved and never restored, with --quiet hiding even the warning.
  #
  # `git ls-tree -z` plus split /\0/ removes the quoting rather than undoing
  # it, and covers the ignore list the same way.

  my $repo = new_repo();

  my %name = (
    plain      => 'plain',
    space      => 'with space',
    colon      => 'with:colon',
    dash       => '-leading-dash',
    yaml_yes   => 'yes',
    numeric    => '123',
    dquote     => 'with"quote',
    backslash  => 'with\\backslash',
    utf8       => "caf\xc3\xa9",
    newline    => "new\nline",
  );

  for my $label ( sort keys %name ) {

    my $path = File::Spec->catfile( $repo->{ root }, $name{ $label } );

    open my $fh, '>', $path or die "create $label: $!";
    print { $fh } "x\n";
    close $fh;

    # Explicit, so the restore below is measured against a known mode rather
    # than whatever the ambient umask produced.
    chmod 0644, $path;

  }

  commit_all( $repo, 'initial' );

  my $result = run_script( $repo, ['--save'] );

  is $result->{ exit }, 0, '--save still exits 0';

  my $names = note_names( $repo );

  # Names git passes through verbatim.
  ok $names->{ $name{ $_ } }, "'$_' is recorded"
    for qw( plain space colon dash yaml_yes numeric );

  # Names git would have quoted.
  ok $names->{ $name{ $_ } }, "'$_' is recorded"
    for qw( dquote backslash utf8 newline );

  unlike $result->{ stderr }, qr/Problem getting stat on/,
    'no path was handed to lstat in its quoted form';

  # The restore side reads the same list, so it has to match the names back to
  # their own entries rather than skipping them.
  chmod 0600, File::Spec->catfile( $repo->{ root }, $_ ) for values %name;

  my $set = run_script( $repo, [ '--set', '--quiet' ] );

  is $set->{ exit }, 0, '--set succeeded';

  for my $label ( sort keys %name ) {

    my $mode = ( stat File::Spec->catfile( $repo->{ root }, $name{ $label } ) )[2] & 07777;

    is sprintf( '%04o', $mode ), '0644', "'$label' was restored to its own mode";

  }

};

subtest 'a name that survives quoting round-trips through the note' => sub {

  my $repo = new_repo();

  my @names = ( 'plain', 'with space', 'with:colon', "with'quote", '-leading-dash',
    'yes', 'no', 'null', '123', '0644', 'with#hash', '100%', '@anchor', '*glob' );

  for my $name ( @names ) {

    my $path = File::Spec->catfile( $repo->{ root }, $name );

    open my $fh, '>', $path or die "create '$name': $!";
    print { $fh } "x\n";
    close $fh;

    chmod 0640, $path;

  }

  commit_all( $repo, 'initial' );

  run_script( $repo, ['--save'] );

  my $names = note_names( $repo );

  ok $names->{ $_ }, "'$_' is recorded" for @names;

  # Perturb every mode, restore, and confirm each name was matched back to its
  # own entry rather than to a neighbour's.
  chmod 0600, File::Spec->catfile( $repo->{ root }, $_ ) for @names;

  # --quiet, which is what the hooks pass. '100%' in this list used to make
  # the run's own progress message a sprintf format hazard; that defect has
  # its own subtest below and no longer decides the outcome here.
  my $result = run_script( $repo, [ '--set', '--quiet' ] );

  is $result->{ exit }, 0, '--set succeeded';

  for my $name ( @names ) {

    my $mode = ( stat File::Spec->catfile( $repo->{ root }, $name ) )[2] & 07777;

    is sprintf( '%04o', $mode ), '0640', "'$name' was restored to its own mode";

  }

};

subtest 'a filename containing % is not injected into a sprintf format' => sub {

  # Issue #17. chmod_file used to build its progress message as
  #
  #     warn sprintf "chmod %04o, @files\n", oct $chmod;
  #
  # which interpolated the filenames into the *format string* rather than
  # passing them as arguments, so a tracked file whose name contained '%'
  # supplied format directives of its own:
  #
  #     '100%n'  -> %n  -> fatal, the whole run died
  #     'a%sb'   -> %s  -> "Missing argument", and the name was corrupted to
  #                        'ab' in the message
  #     '100%'   -> %\n -> "Invalid conversion", message only
  #
  # The fatal case was the damaging one: it aborted --set *after* chown_file
  # had run and *before* chmod_file, touch_file, and extnd_attr, leaving the
  # tree half restored with no indication which files were reached.
  #
  # --quiet suppressed the warn and so avoided the whole thing, which is why
  # the post-commit and post-checkout hooks never tripped over it.
  #
  # sibling: chown_file and touch_file interpolate into a plain string and
  # were never affected; set_metadata_in_system passes names as a sprintf
  # argument and was always correct.

  my $repo = new_repo();

  # '100%n' was the fatal directive; 'a%sb' silently corrupted the name it
  # was reported under. Both have to survive verbatim now.
  my @names = ( '100%n', 'a%sb', '100%' );

  for my $name ( @names ) {

    my $path = File::Spec->catfile( $repo->{ root }, $name );

    open my $fh, '>', $path or die "create '$name': $!";
    print { $fh } "x\n";
    close $fh;

    chmod 0640, $path;

  }

  commit_all( $repo, 'initial' );

  my $save = run_script( $repo, ['--save'] );

  is $save->{ exit }, 0, '--save is unaffected (it has no such sprintf)';

  chmod 0600, File::Spec->catfile( $repo->{ root }, $_ ) for @names;

  my $noisy = run_script( $repo, ['--set'] );

  is $noisy->{ exit }, 0, '--set survives a filename containing %n';

  unlike $noisy->{ stderr }, qr/Missing argument|Invalid conversion|read-only value/,
    '...with no sprintf complaint about an injected directive';

  like $noisy->{ stderr }, qr/^chmod /m, '...and chmod_file was reached';

  like $noisy->{ stderr }, qr/\Qa%sb\E/,
    '...reporting the name verbatim rather than swallowing the directive';

  for my $name ( @names ) {

    my $mode = ( stat File::Spec->catfile( $repo->{ root }, $name ) )[2] & 07777;

    is sprintf( '%04o', $mode ), '0640', "'$name' was restored";

  }

  # The same restore under the flag the hooks use.
  my $quiet = run_script( $repo, [ '--set', '--quiet' ] );

  is $quiet->{ exit }, 0, '--quiet completes too';

};

done_testing();
