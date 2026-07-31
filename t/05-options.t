#!/usr/bin/env perl

# Command-line handling. All of it runs *after* the repository paths are
# derived, which is itself observable: --help does not work outside a
# repository.

use strict;
use warnings;

use lib 't/lib';

use Test::More;

use GitPerms::Test::Repo qw( git_available new_repo git_in write_file commit_all run_script note_for_head );

plan skip_all => 'git is not available'
  if !git_available();

my $repo = new_repo();

write_file( $repo, 'plain', "content\n" );
commit_all( $repo, 'initial' );

#-------------------------------------------------------------------------------

subtest '--help' => sub {

  my $result = run_script( $repo, ['--help'] );

  isnt $result->{ exit }, 0, '--help exits non-zero (it dies with the usage text)';

  like $result->{ stderr }, qr/usage:/,       'usage line is shown';
  like $result->{ stderr }, qr/--save/,       '--save is documented';
  like $result->{ stderr }, qr/--set/,        '--set is documented';
  like $result->{ stderr }, qr/--force/,      '--force is documented';
  like $result->{ stderr }, qr/--quiet/,      '--quiet is documented';
  like $result->{ stderr }, qr/--create-on-missing/, '--create-on-missing is documented';

};

subtest 'neither --save nor --set' => sub {

  my $result = run_script( $repo, [] );

  isnt $result->{ exit }, 0, 'exits non-zero';
  like $result->{ stderr }, qr/either --save or --set is required/, 'says which options are needed';
  unlike $result->{ stdout }, qr/Done/, 'nothing was done';

};

subtest '--save and --set together' => sub {

  my $result = run_script( $repo, [ '--save', '--set' ] );

  isnt $result->{ exit }, 0, 'exits non-zero';
  like $result->{ stderr }, qr/mutually exclusive/, 'says they are mutually exclusive';
  unlike $result->{ stdout }, qr/Done/, 'nothing was done';

  ok !defined note_for_head( $repo ), 'and no note was written';

};

subtest 'an unrecognised option' => sub {

  my $result = run_script( $repo, [ '--save', '--no-such-option' ] );

  isnt $result->{ exit }, 0, 'exits non-zero';
  like $result->{ stderr }, qr/Problem parsing options/, 'reports the parse failure';

};

subtest '--save succeeds and --set consumes what it wrote' => sub {

  my $save = run_script( $repo, ['--save'] );

  is $save->{ exit }, 0, '--save exits 0';
  like $save->{ stdout }, qr/Done saving/, '--save reports completion';

  ok defined note_for_head( $repo ), 'a note exists';

  my $set = run_script( $repo, ['--set'] );

  is $set->{ exit }, 0, '--set exits 0';
  like $set->{ stdout }, qr/Done setting/, '--set reports completion';

};

subtest '--force' => sub {

  run_script( $repo, ['--save'] );

  my $first = note_for_head( $repo );
  ok defined $first, 'a note exists to overwrite';

  # git notes refuses to replace an existing note; without --force the script
  # only warns about it.
  my $plain = run_script( $repo, ['--save'] );

  like $plain->{ stderr }, qr/note|exists|overwrite/i, 'a second --save without --force complains';

  my $forced = run_script( $repo, [ '--save', '--force' ] );

  is $forced->{ exit }, 0, '--save --force exits 0';
  like $forced->{ stdout }, qr/Done saving/, '--force completes the save';

};

subtest '--quiet' => sub {

  my $noisy = run_script( $repo, [ '--set' ] );
  my $quiet = run_script( $repo, [ '--set', '--quiet' ] );

  is $quiet->{ exit }, 0, '--quiet still exits 0';

  cmp_ok length $quiet->{ stderr }, '<=', length $noisy->{ stderr },
    '--quiet does not produce more diagnostics than a normal run';

  like $quiet->{ stdout }, qr/Done setting/,
    '--quiet still prints the completion line (it only suppresses warnings)';

};

subtest 'the SELinux probe runs unconditionally' => sub {

  # $se_enforcing is filled by `cat /selinux/enforce` at startup, before any
  # option is parsed. On a system without that path -- which is every current
  # distribution, they moved it to /sys/fs/selinux/enforce -- cat's complaint
  # is emitted on every single invocation, including under --quiet. Issue #7.

  my $result = run_script( $repo, [ '--save', '--force', '--quiet' ] );

  SKIP: {

    skip '/selinux/enforce exists on this host', 1
      if -e '/selinux/enforce';

    like $result->{ stderr }, qr{/selinux/enforce},
      '[#7] the missing /selinux/enforce is reported on stderr even under --quiet';

  }

  is $result->{ exit }, 0, 'the probe does not stop the run';

};

done_testing();
