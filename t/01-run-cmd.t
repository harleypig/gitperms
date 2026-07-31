#!/usr/bin/env perl

# run_cmd replaced IPC::Run3::Simple::run3. Five call sites depend on its
# ( $stdout, $stderr, $syserr ) return, on the two streams staying separate,
# and on neither stream being able to stall the other.

use strict;
use warnings;

use lib 't/lib';

use Test::More;

use GitPerms::Test::Harness ();
use GitPerms::Test::Repo qw( run_with_timeout );

my $pkg = GitPerms::Test::Harness::load();

my $run_cmd = $pkg->can( 'run_cmd' )
  or plan skip_all => 'handle_metadata has no run_cmd';

#-------------------------------------------------------------------------------
# Shape of the return value

{
  my @result = $run_cmd->( $^X, '-e', 'print "hello\n"' );

  is scalar @result, 3, 'run_cmd returns a three-element list';

  my ( $out, $err, $syserr ) = @result;

  is $out,    'hello', 'stdout is captured';
  is $err,    q{},     'stderr is empty when the command writes none';
  is $syserr, 0,       '$syserr is 0 for a successful command';
}

#-------------------------------------------------------------------------------
# Exactly one trailing newline is chomped -- get_toplevel and get_git_dir feed
# the result straight to abs_path/canonpath and then chdir, so an unchomped
# newline breaks the script outright, and an over-eager chomp would corrupt a
# path that legitimately ends in one.

{
  my ( $out ) = $run_cmd->( $^X, '-e', 'print "/some/path\n"' );
  is $out, '/some/path', 'a single trailing newline is removed';
}

{
  my ( $out ) = $run_cmd->( $^X, '-e', 'print "a\n\n"' );
  is $out, "a\n", 'only one trailing newline is removed';
}

{
  my ( $out ) = $run_cmd->( $^X, '-e', 'print "no-newline"' );
  is $out, 'no-newline', 'output with no trailing newline is unchanged';
}

{
  my ( $out ) = $run_cmd->( $^X, '-e', 'print "a\nb\nc\n"' );
  is $out, "a\nb\nc", 'interior newlines survive; callers split on them';
}

#-------------------------------------------------------------------------------
# Stream separation. IPC::Open3 merges stderr into stdout when its third
# argument is false, which would quietly poison every caller: get_git_dir and
# get_toplevel die when stderr is non-empty, and get_note branches on its
# content. The gensym in run_cmd is what prevents that.

{
  my ( $out, $err, $syserr ) = $run_cmd->( $^X, '-e', 'print STDOUT "OUT\n"; print STDERR "ERR\n";' );

  is $out, 'OUT', 'stdout carries only what the child wrote to stdout';
  is $err, 'ERR', 'stderr is captured on its own handle, not merged into stdout';
  unlike $out, qr/ERR/, 'stderr does not leak into stdout';
  is $syserr, 0, 'writing to stderr alone is not an error';
}

{
  # Interleaved writes are the case a merged handle scrambles.
  my $prog = 'for my $i (1..50) { print STDOUT "o$i\n"; print STDERR "e$i\n" }';
  my ( $out, $err ) = $run_cmd->( $^X, '-e', $prog );

  is scalar( () = $out =~ /^o\d+$/mg ), 50, 'all stdout lines land in stdout';
  is scalar( () = $err =~ /^e\d+$/mg ), 50, 'all stderr lines land in stderr';
  unlike $out, qr/^e\d+$/m, 'no stderr line appears in stdout under interleaving';
}

#-------------------------------------------------------------------------------
# Concurrent draining. A pipe buffer is 64 KiB by default; draining one stream
# to EOF before touching the other deadlocks as soon as the child fills the
# untouched one. `git ls-tree -r -t HEAD` on a real repository clears 64 KiB
# easily, and a chatty git writes warnings to stderr at the same time.

my $big = 256 * 1024;

{
  my ( $timed_out, $exit ) = run_with_timeout(
    30,
    sub {
      my ( $out, $err ) = $run_cmd->( $^X, '-e', "print STDERR 'e' x $big; print STDOUT \"done\\n\";" );
      die 'wrong lengths' if length( $err ) != $big || $out ne 'done';
      return;
    }
  );

  ok !$timed_out, "stderr larger than the pipe buffer ($big bytes) does not deadlock";
  is $exit, 0, '...and both streams come back intact';
}

{
  my ( $timed_out, $exit ) = run_with_timeout(
    30,
    sub {
      my ( $out, $err ) = $run_cmd->( $^X, '-e', "print STDOUT 'o' x $big; print STDERR \"note\\n\";" );
      die 'wrong lengths' if length( $out ) != $big || $err ne 'note';
      return;
    }
  );

  ok !$timed_out, 'stdout larger than the pipe buffer does not deadlock';
  is $exit, 0, '...and both streams come back intact';
}

{
  my ( $timed_out, $exit ) = run_with_timeout(
    30,
    sub {
      my ( $out, $err ) = $run_cmd->( $^X, '-e', "print STDOUT 'o' x $big; print STDERR 'e' x $big;" );
      die 'wrong lengths' if length( $out ) != $big || length( $err ) != $big;
      return;
    }
  );

  ok !$timed_out, 'both streams over the pipe buffer at once do not deadlock';
  is $exit, 0, '...and both come back at full length';
}

#-------------------------------------------------------------------------------
# Failure paths

{
  my ( $out, $err, $syserr ) = $run_cmd->( $^X, '-e', 'exit 3' );

  is $syserr >> 8, 3, 'a non-zero exit status is reported through $syserr';
  ok $syserr, '$syserr is true so callers can detect the failure';
  is $out, q{}, 'no stdout from a failing command';
}

{
  # get_git_dir and get_toplevel die on $syserr before they look at $err, so a
  # command that cannot be spawned has to surface as an error, not as silence.
  my ( $out, $err, $syserr ) = $run_cmd->( 'gitperms-no-such-command-exists' );

  is $syserr, -1, 'a command that cannot be spawned returns -1 as $syserr';
  is $out, q{}, '...with empty stdout';
  ok length $err, '...and the reason in $err';
}

#-------------------------------------------------------------------------------
# Reporting that status to a person. $syserr is a wait(2) status, not an exit
# code: get_git_dir and get_toplevel printed it raw, so git's exit 128 reached
# the user as "System error: 32768".

{
  my $describe = $pkg->can( 'describe_status' )
    or die "handle_metadata has no describe_status\n";

  my ( undef, undef, $exited ) = $run_cmd->( $^X, '-e', 'exit 128' );

  is $describe->( $exited ), 'exited 128', 'an exit status is reported as its high byte';

  my ( undef, undef, $signalled ) = $run_cmd->( $^X, '-e', 'kill 9, $$; sleep 10' );

  SKIP: {

    skip 'the child was not killed by a signal on this host', 1
      if !( $signalled & 127 );

    is $describe->( $signalled ), 'was killed by signal 9',
      'a signal is named as a signal, not folded into an exit code';

  }

  my ( undef, undef, $unspawnable ) = $run_cmd->( 'gitperms-no-such-command-exists' );

  is $describe->( $unspawnable ), 'could not be run',
    'run_cmd\'s -1 is not read as a status at all';

  is $describe->( 0 ), 'exited 0', 'success is still describable';
}

#-------------------------------------------------------------------------------
# No shell. run3 was called with a list and so is open3; a caller passing a
# path containing shell metacharacters must not have them interpreted.

{
  my ( $out ) = $run_cmd->( $^X, '-e', 'print $ARGV[0]', 'a;b|c $HOME `id` *' );

  is $out, 'a;b|c $HOME `id` *', 'arguments reach the child uninterpreted (no shell)';
}

{
  my ( $out, $err, $syserr ) = $run_cmd->( $^X, '-e', 'print ""' );

  is $out,    q{}, 'an empty stdout is the empty string, not undef';
  is $err,    q{}, 'an empty stderr is the empty string, not undef';
  is $syserr, 0,   'and the command still reports success';
}

done_testing();
