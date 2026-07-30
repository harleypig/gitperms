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

subtest 'a file whose name git C-quotes is silently dropped' => sub {

  # `git ls-tree` C-quotes any path containing a double quote, a backslash, a
  # control character, or (unless core.quotePath is false) a byte above 0x7f.
  # The script never unquotes, so lstat is handed the *quoted* string, fails,
  # and the file is skipped with a warning. Its metadata is never saved and
  # never restored.
  #
  # `git ls-tree -z` plus split /\0/ would fix both this and the equivalent
  # problem in the ignore list.

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

  }

  commit_all( $repo, 'initial' );

  my $result = run_script( $repo, ['--save'] );

  is $result->{ exit }, 0, '--save still exits 0';

  my $names = note_names( $repo );

  # Names git passes through verbatim are handled correctly.
  ok $names->{ $name{ $_ } }, "'$_' is recorded"
    for qw( plain space colon dash yaml_yes numeric );

  # Names git quotes are not.
  for my $label ( qw( dquote backslash utf8 newline ) ) {

    ok !$names->{ $name{ $label } },
      "current behaviour: '$label' is missing from the note (git quoted the path)";

    like $result->{ stderr }, qr/Problem getting stat on/,
      "...and the run warned about it"
      if $label eq 'dquote';

  }

  TODO: {
    local $TODO = 'git ls-tree C-quotes these paths; the script does not unquote them';

    ok $names->{ $name{ $_ } }, "'$_' should be recorded"
      for qw( dquote backslash utf8 newline );
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

  # --quiet, which is what the hooks pass, and what keeps this deterministic:
  # without it, chmod_file interpolates these names into a sprintf format and
  # '100%' can abort the run depending on which name follows it. That is a
  # real defect, characterised on its own in the next subtest; it does not
  # belong in the middle of a round-trip test.
  my $result = run_script( $repo, [ '--set', '--quiet' ] );

  is $result->{ exit }, 0, '--set succeeded';

  for my $name ( @names ) {

    my $mode = ( stat File::Spec->catfile( $repo->{ root }, $name ) )[2] & 07777;

    is sprintf( '%04o', $mode ), '0640', "'$name' was restored to its own mode";

  }

};

subtest 'a filename containing % is injected into a sprintf format' => sub {

  # chmod_file builds its progress message as
  #
  #     warn sprintf "chmod %04o, @files\n", oct $chmod;
  #
  # so the filenames are interpolated into the *format string* rather than
  # passed as arguments. A tracked file whose name contains '%' therefore
  # supplies format directives:
  #
  #     '100%n'  -> %n  -> fatal, the whole run dies
  #     'a%sb'   -> %s  -> "Missing argument", and the name is corrupted to
  #                        'ab' in the message
  #     '100%'   -> %\n -> "Invalid conversion", message only
  #
  # The fatal case is the damaging one: it aborts --set *after* chown_file has
  # run and *before* chmod_file, touch_file, and extnd_attr, leaving the tree
  # half restored with no indication which files were reached.
  #
  # --quiet suppresses the warn and so avoids the whole thing, which is why
  # the post-commit and post-checkout hooks have never tripped over it.
  #
  # Pre-existing: identical code is on the legacy branch. Not introduced by
  # the modernisation.
  #
  # sibling: chown_file and touch_file interpolate into a plain string and are
  # unaffected; set_metadata_in_system passes names as a sprintf argument and
  # is correct.

  my $repo = new_repo();

  my $name = '100%n';
  my $path = File::Spec->catfile( $repo->{ root }, $name );

  open my $fh, '>', $path or die "create '$name': $!";
  print { $fh } "x\n";
  close $fh;

  chmod 0640, $path;

  commit_all( $repo, 'initial' );

  my $save = run_script( $repo, ['--save'] );

  is $save->{ exit }, 0, '--save is unaffected (it has no such sprintf)';

  chmod 0600, $path;

  my $noisy = run_script( $repo, ['--set'] );

  isnt $noisy->{ exit }, 0, 'current behaviour: --set dies on a name containing %n';

  # perl >= 5.30 says "Missing argument for %n in sprintf"; perl 5.22 says
  # "Missing argument in sprintf" and then dies with "Modification of a
  # read-only value attempted". Same injection either way.
  like $noisy->{ stderr },
    qr/Missing argument for %n in sprintf|Modification of a read-only value attempted/,
    '...with a sprintf error caused by the injected directive';

  is sprintf( '%04o', ( stat $path )[2] & 07777 ), '0600',
    '...leaving the mode unrestored: the run aborted before chmod_file';

  like $noisy->{ stderr }, qr/^chown /m,
    '...but after chown_file, so the restore is half applied';

  # The same restore under the flag the hooks use.
  my $quiet = run_script( $repo, [ '--set', '--quiet' ] );

  is $quiet->{ exit }, 0, '--quiet completes because the warn is never built';

  is sprintf( '%04o', ( stat $path )[2] & 07777 ), '0640',
    '...and the mode is restored';

  TODO: {
    local $TODO = 'chmod_file interpolates @files into its sprintf format string';

    isnt $noisy->{ exit }, 255, '--set should not die on a filename containing %';
  }

};

done_testing();
