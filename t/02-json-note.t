#!/usr/bin/env perl

# The note format moved from YAML::Syck to JSON::PP, a deliberate breaking
# change with no migration. The metadata is numeric-heavy and its leaf values
# are filenames, so the two things worth proving are that numbers survive as
# numbers and that awkward names survive as themselves.

use strict;
use warnings;

use lib 't/lib';

use Test::More;

use File::Spec ();
use JSON::PP   ();

use GitPerms::Test::Harness ();
use GitPerms::Test::Repo qw( git_available new_repo git_in write_file commit_all note_for_head );

my $pkg = GitPerms::Test::Harness::load();

#-------------------------------------------------------------------------------
# Filenames that have historically broken one serialiser or another. The YAML
# group matters because these used to be YAML documents: unquoted, YAML 1.1
# reads `yes` as a boolean and `123` as an integer.

my @AWKWARD_NAMES = (
  [ plain        => 'plain' ],
  [ space        => 'with space' ],
  [ colon        => 'with:colon' ],
  [ colon_space  => 'key: value' ],
  [ dquote       => 'with"quote' ],
  [ squote       => "with'quote" ],
  [ backslash    => 'with\\backslash' ],
  [ newline      => "with\nnewline" ],
  [ tab          => "with\ttab" ],
  [ utf8         => "caf\xc3\xa9" ],
  [ latin1       => "na\xefve" ],
  [ leading_dash => '-leading-dash' ],
  [ dash_dash    => '--option-lookalike' ],
  [ yaml_yes     => 'yes' ],
  [ yaml_no      => 'no' ],
  [ yaml_null    => 'null' ],
  [ yaml_tilde   => '~' ],
  [ yaml_on      => 'on' ],
  [ numeric      => '123' ],
  [ float        => '1.20' ],
  [ octal_ish    => '0644' ],
  [ hash         => 'with#hash' ],
  [ brace        => 'with{brace}' ],
  [ bracket      => 'with[bracket]' ],
  [ percent      => '100%' ],
  [ at_sign      => '@anchor' ],
  [ ampersand    => '&anchor' ],
  [ asterisk     => '*glob' ],
);

#-------------------------------------------------------------------------------
# Pure serialiser fidelity, using the same JSON::PP configuration set_note and
# get_note use.

my $encoder = JSON::PP->new->utf8->canonical->pretty;
my $decoder = JSON::PP->new->utf8;

{
  # Field names and representative values taken from what File::stat feeds
  # get_metadata_from_system. Every one of these is consumed numerically on
  # restore -- mode by S_ISFIFO/S_ISCHR/S_ISBLK, rdev by the major/minor
  # arithmetic, atime and mtime by utime, uid and gid by chown.
  my %inode = (
    dev        => 2049,
    ino        => 1234567,
    mode       => 33188,
    nlink      => 1,
    uid        => 1000,
    gid        => 1000,
    rdev       => 0,
    size       => 0,
    atime      => 1_600_000_000,
    mtime      => 1_600_000_001,
    ctime      => 1_600_000_002,
    blksize    => 4096,
    blocks     => 0,
    extnd_attr => 0x40,
    chmod      => '0644',
    name       => ['plain'],
  );

  my $round = $decoder->decode( $encoder->encode( { sha => { 1234567 => \%inode } } ) );
  my $back  = $round->{ sha }{ 1234567 };

  for my $field ( grep { $_ ne 'name' && $_ ne 'chmod' } sort keys %inode ) {

    is $back->{ $field }, $inode{ $field }, "$field survives the round trip";

    # A number that came back as a string still compares equal with ==, so the
    # representation has to be checked directly.
    my $encoded = $encoder->encode( { v => $back->{ $field } } );
    like $encoded, qr/"v"\s*:\s*-?\d/, "$field re-encodes as a JSON number, not a string";

  }

  is $back->{ chmod }, '0644', 'chmod survives as its zero-padded string';
  like $encoder->encode( { v => $back->{ chmod } } ), qr/"v"\s*:\s*"0644"/,
    'chmod stays a JSON string so oct() still sees the leading zero';

  is_deeply $back->{ name }, ['plain'], 'the name list survives as an array';
}

{
  # A large device number must not be mangled. 8:0 and 253:1 are ordinary, but
  # a 64-bit rdev exercises the integer path properly.
  for my $rdev ( 0, 2048, 64_768, 4_294_967_296, 18_446_744_073 ) {

    my $back = $decoder->decode( $encoder->encode( { rdev => $rdev } ) );
    is $back->{ rdev }, $rdev, "rdev $rdev survives the round trip exactly";

  }
}

{
  for my $case ( @AWKWARD_NAMES ) {

    my ( $label, $name ) = @$case;

    my $back = $decoder->decode( $encoder->encode( { name => [$name] } ) );

    is $back->{ name }[0], $name, "filename '$label' survives JSON encode/decode";

  }
}

{
  # `git notes show` hands the note back as bytes on a single stream, so a
  # control character in a name must be escaped rather than emitted raw.
  # Checked against the compact form, where the only newline that could appear
  # is one JSON::PP failed to escape (pretty-printing adds structural ones).
  my $compact = JSON::PP->new->utf8->canonical->encode( { name => [ "with\nnewline\twith\ttab" ] } );

  unlike $compact, qr/\n/, 'a newline in a name is never emitted raw';
  unlike $compact, qr/\t/, 'a tab in a name is never emitted raw';
  like $compact, qr/\\n/, '...the newline is escaped';
  like $compact, qr/\\t/, '...and so is the tab';
}

{
  # canonical is what keeps successive notes diffing cleanly.
  my %h = map { $_ => 1 } qw( zebra alpha mike bravo );

  is $encoder->encode( \%h ), $encoder->encode( \%h ), 'canonical encoding is stable across calls';
  like $encoder->encode( \%h ), qr/alpha.*bravo.*mike.*zebra/s, 'keys are emitted in sorted order';
}

#-------------------------------------------------------------------------------
# set_note / get_note against a real repository.

SKIP: {

  skip 'git is not available', 1
    if !git_available();

  my $repo = new_repo();

  write_file( $repo, 'plain', "content\n" );
  commit_all( $repo, 'initial' );

  # set_note and get_note shell out to git. The script points them at the
  # repository by exporting GIT_DIR and GIT_WORK_TREE before calling them, so
  # do the same here rather than changing directory.
  local %ENV = ( %ENV, %{ $repo->{ env } } );
  delete $ENV{ $_ } for grep { !defined $repo->{ env }{ $_ } } keys %{ $repo->{ env } };

  local $ENV{ GIT_DIR }       = File::Spec->catdir( $repo->{ root }, '.git' );
  local $ENV{ GIT_WORK_TREE } = $repo->{ root };

  subtest 'set_note then get_note' => sub {

    my %metadata = (
      abc123 => {
        99 => {
          type       => 'RF',
          mode       => 33188,
          uid        => 1000,
          gid        => 1000,
          rdev       => 0,
          atime      => 1_600_000_000,
          mtime      => 1_600_000_001,
          chmod      => '0644',
          extnd_attr => 64,
          name       => [ 'plain', 'with space', "caf\xc3\xa9", '-leading-dash', 'yes', '123' ],
        },
      },
    );

    $pkg->can( 't_set_metadata' )->( \%metadata );
    $pkg->can( 't_set_quiet' )->( 1 );
    $pkg->can( 'set_note' )->();

    my $raw = note_for_head( $repo );

    ok defined $raw && length $raw, 'a note was attached to HEAD';

    # Clear the in-memory copy so get_note has to repopulate it from git.
    $pkg->can( 't_set_metadata' )->( {} );
    is_deeply $pkg->can( 't_get_metadata' )->(), {}, 'metadata cleared before reading back';

    ok $pkg->can( 'get_note' )->(), 'get_note reports the note existed';

    my $back = $pkg->can( 't_get_metadata' )->();

    is_deeply $back, \%metadata, 'the note round-trips through git notes unchanged';

    is $back->{ abc123 }{ 99 }{ mode }, 33188, 'mode came back as a number';
    is $back->{ abc123 }{ 99 }{ chmod }, '0644', 'chmod came back as a string';

    # Part of issue #18. A path is bytes, and decoding the note turns those
    # bytes into characters -- perl then hands such a string to chmod/utime as
    # its UTF-8 *encoding*, which is not the name on disk, so the restore
    # silently misses every non-ASCII file. get_note puts the names back.
    my $utf8_name = $back->{ abc123 }{ 99 }{ name }[2];

    is $utf8_name, "caf\xc3\xa9", 'a non-ASCII name survives the round trip';
    ok !utf8::is_utf8( $utf8_name ), '...as bytes, the way the filesystem takes it';

    # Restore uses these numerically; a stringified value would still work with
    # ==, so re-encode and inspect the representation.
    for my $field ( qw( mode uid gid rdev atime mtime extnd_attr ) ) {

      my $reencoded = JSON::PP->new->encode( { v => $back->{ abc123 }{ 99 }{ $field } } );

      like( $reencoded, qr/"v":-?\d+/, "$field is still a number after a git notes round trip" );

    }

  };

  subtest 'get_note when no note exists' => sub {

    git_in( $repo, 'notes', '--ref', 'gitperms', 'remove', 'HEAD' );

    $pkg->can( 't_set_metadata' )->( {} );

    my ( $printed, $warned, $result ) = _call_get_note( $pkg );

    ok !$result, 'get_note reports failure when there is no note';
    is_deeply $pkg->can( 't_get_metadata' )->(), {}, 'no metadata is invented';

    # Characterises issue #13. git lowercased its message to "no note found
    # for object", so get_note's /No note found for object/ never matches and
    # the missing-note branch is unreachable: the generic error path runs
    # instead. These two assertions record what happens today; Phase 2 flips
    # them when the match is fixed.
    like $warned, qr/no note found for object/i,
      '[#13] the missing-note case currently falls through to the generic error branch';
    is $printed, q{},
      '[#13] ...so the guidance text is never printed';

    TODO: {
      local $TODO = 'issue #13: get_note matches /No note found/ but git says "no note found"';

      like $printed, qr/does not have a note associated with it/,
        'the missing-note guidance should be printed';
    }

  };

  subtest '--create-on-missing' => sub {

    git_in( $repo, 'notes', '--ref', 'gitperms', 'remove', 'HEAD' );

    $pkg->can( 't_set_create_on_missing' )->( 1 );
    $pkg->can( 't_set_files' )->();
    $pkg->can( 't_set_metadata' )->( {} );

    my ( $printed, $warned, $result ) = _call_get_note( $pkg );

    $pkg->can( 't_set_create_on_missing' )->( undef );

    TODO: {
      local $TODO = 'issue #13: --create-on-missing is unreachable for the same reason';

      like $printed, qr/Missing note created/, '--create-on-missing creates the note';
      ok defined note_for_head( $repo ), '...and a note now exists on HEAD';
    }

  };

  subtest 'set_note without --force over an existing note' => sub {

    $pkg->can( 't_set_metadata' )->( { sha => { 1 => { name => ['plain'] } } } );
    $pkg->can( 't_set_force' )->( undef );
    $pkg->can( 'set_note' )->();

    my $first = note_for_head( $repo );
    ok defined $first, 'first note written';

    $pkg->can( 't_set_metadata' )->( { sha => { 2 => { name => ['other'] } } } );

    my @warnings;
    local $SIG{ __WARN__ } = sub { push @warnings, @_ };

    $pkg->can( 't_set_quiet' )->( undef );
    $pkg->can( 'set_note' )->();

    ok scalar @warnings, 'git refusing to overwrite is surfaced as a warning';

    is note_for_head( $repo ), $first, 'the existing note is left untouched without --force';

    # ...and --force replaces it.
    $pkg->can( 't_set_force' )->( 1 );
    $pkg->can( 't_set_quiet' )->( 1 );
    $pkg->can( 'set_note' )->();

    isnt note_for_head( $repo ), $first, '--force overwrites the existing note';

  };

}

#-------------------------------------------------------------------------------
# get_note prints on stdout and warns on stderr; both have to be captured to
# tell its three branches apart.

sub _call_get_note {

  my ( $package ) = @_;

  my ( $printed, $warned ) = ( q{}, q{} );

  local $SIG{ __WARN__ } = sub { $warned .= join q{}, @_ };

  open my $capture, '>', \$printed or die "in-memory capture failed: $!";

  my $old = select $capture;  ## no critic ( InputOutput::ProhibitOneArgSelect )

  my $result = eval { $package->can( 'get_note' )->() };

  select $old;                ## no critic ( InputOutput::ProhibitOneArgSelect )

  close $capture;

  return ( $printed, $warned, $result );

}

done_testing();
