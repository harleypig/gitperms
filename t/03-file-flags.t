#!/usr/bin/env perl

# Linux::Ext2::Attributes was replaced with a core ioctl call whose request
# numbers are *derived* from sizeof(long) rather than hardcoded. The
# derivation, the read, and the read-only-flag handling are each checked
# separately, because a wrong constant fails silently: ioctl just returns
# undef and the script warns about "extended attributes" and carries on.

use strict;
use warnings;

use lib 't/lib';

use Test::More;

use Config     ();
use File::Spec ();
use File::Temp qw( tempdir );
use POSIX      ();

use GitPerms::Test::Harness ();
use GitPerms::Test::Repo qw( capture run_with_timeout );

my $pkg = GitPerms::Test::Harness::load();

plan skip_all => 'ext2 attribute ioctls are Linux-only'
  if $^O ne 'linux';

my $tmp = tempdir( 'gitperms-flags-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

#-------------------------------------------------------------------------------
# The derivation itself.
#
# asm-generic/ioctl.h encodes a request as
#     direction << 30 | size << 16 | type << 8 | number
# with _IOC_READ = 2 and _IOC_WRITE = 1, and linux/fs.h declares
#     FS_IOC_GETFLAGS = _IOR( 'f', 1, long )
#     FS_IOC_SETFLAGS = _IOW( 'f', 2, long )
# so both values move with sizeof(long): 0x80086601 / 0x40086602 on a 64-bit
# build and 0x80046601 / 0x40046602 on a 32-bit one.

{
  is $pkg->LONG_SIZE, $Config::Config{ longsize },
    'LONG_SIZE matches the running perl\'s sizeof(long)';

  my $size = $pkg->LONG_SIZE;

  is $pkg->FS_IOC_GETFLAGS, ( 2 << 30 ) | ( $size << 16 ) | ( 0x66 << 8 ) | 1,
    'FS_IOC_GETFLAGS follows the _IOR( f, 1, long ) encoding';

  is $pkg->FS_IOC_SETFLAGS, ( 1 << 30 ) | ( $size << 16 ) | ( 0x66 << 8 ) | 2,
    'FS_IOC_SETFLAGS follows the _IOW( f, 2, long ) encoding';

  # Pin the two concrete values so a change to the derivation cannot quietly
  # produce a number that is merely self-consistent.
  my %expected = (
    8 => [ 0x80086601, 0x40086602 ],
    4 => [ 0x80046601, 0x40046602 ],
  );

  SKIP: {

    skip "no reference values for a ${size}-byte long", 2
      if !exists $expected{ $size };

    is sprintf( '0x%x', $pkg->FS_IOC_GETFLAGS ), sprintf( '0x%x', $expected{ $size }[0] ),
      "FS_IOC_GETFLAGS is the documented value for a ${size}-byte long";

    is sprintf( '0x%x', $pkg->FS_IOC_SETFLAGS ), sprintf( '0x%x', $expected{ $size }[1] ),
      "FS_IOC_SETFLAGS is the documented value for a ${size}-byte long";

  }

  isnt $pkg->FS_IOC_GETFLAGS, $pkg->FS_IOC_SETFLAGS, 'the two requests are distinct';
}

#-------------------------------------------------------------------------------
# The read-only mask. These are the bits the kernel reports but will not accept
# back, so they are stripped from a saved snapshot and taken from the file on
# restore. Their values come from linux/fs.h.

{
  my %flag = (
    FS_DIRTY_FL     => 0x00000100,
    FS_NOCOMP_FL    => 0x00000400,
    FS_ECOMPR_FL    => 0x00000800,
    FS_INDEX_FL     => 0x00001000,
    FS_HUGE_FILE_FL => 0x00040000,
    FS_EXTENT_FL    => 0x00080000,
  );

  is $pkg->$_(), $flag{ $_ }, "$_ matches linux/fs.h" for sort keys %flag;

  my $union = 0;
  $union |= $flag{ $_ } for keys %flag;

  is $pkg->FS_READONLY_FLAGS, $union, 'FS_READONLY_FLAGS is the union of those six bits';
  is sprintf( '0x%x', $pkg->FS_READONLY_FLAGS ), '0xc1d00', 'FS_READONLY_FLAGS is 0xC1D00';

  # The two halves of the save/restore split must not overlap or leave a gap.
  is( ( $pkg->FS_READONLY_FLAGS & ~$pkg->FS_READONLY_FLAGS ) & 0xffffffff, 0,
    'the mask and its complement are disjoint' );
}

#-------------------------------------------------------------------------------
# Reading flags off real files.

my $plain = File::Spec->catfile( $tmp, 'plain' );
my $dir   = File::Spec->catdir( $tmp, 'adir' );

open my $fh, '>', $plain or die "create $plain: $!";
print { $fh } "x\n";
close $fh;

mkdir $dir or die "mkdir $dir: $!";

my $get_file_flags = $pkg->can( 'get_file_flags' );
my $set_file_flags = $pkg->can( 'set_file_flags' );

my $supported = defined $get_file_flags->( $plain );

diag 'FS_IOC_GETFLAGS is not supported here (tmpfs and overlayfs do not implement it)'
  if !$supported;

SKIP: {

  skip 'FS_IOC_GETFLAGS unsupported on this filesystem', 6
    if !$supported;

  my $flags = $get_file_flags->( $plain );

  ok defined $flags, 'get_file_flags returns a value for a regular file';
  like $flags, qr/\A\d+\z/, '...and it is a plain non-negative integer';

  ok defined $get_file_flags->( $dir ), 'get_file_flags works on a directory';

  # Nothing above bit 31 can be real: the kernel exchanges a 32-bit int.
  cmp_ok $flags, '<=', 0xffffffff, 'no bits above 32 are reported';

  # What the script actually stores in the note.
  my $stored = $flags & ~$pkg->FS_READONLY_FLAGS & 0xffffffff;

  is( ( $stored & $pkg->FS_READONLY_FLAGS ), 0,
    'the value stored in a note has every read-only bit cleared' );

  SKIP: {

    my $lsattr = _find_in_path( 'lsattr' );

    skip 'lsattr is not installed', 1
      if !defined $lsattr;

    my $reported = _lsattr_flags( $lsattr, $plain );

    skip 'lsattr could not read the file', 1
      if !defined $reported;

    is $flags, $reported, 'get_file_flags agrees with lsattr';

  }

}

#-------------------------------------------------------------------------------
# Failure paths.

{
  is $get_file_flags->( File::Spec->catfile( $tmp, 'does-not-exist' ) ), undef,
    'get_file_flags returns undef for a missing file';

  is $set_file_flags->( File::Spec->catfile( $tmp, 'does-not-exist' ), 0 ), undef,
    'set_file_flags returns undef for a missing file';
}

{
  # get_file_flags opens O_NONBLOCK specifically so a fifo with no writer does
  # not stall the whole run. Without it this call blocks forever.
  my $fifo = File::Spec->catfile( $tmp, 'afifo' );

  SKIP: {

    skip 'mkfifo is unavailable here', 1
      if !eval { POSIX::mkfifo( $fifo, 0600 ) or die; 1 };

    my ( $timed_out ) = run_with_timeout( 15, sub { $get_file_flags->( $fifo ); return } );

    ok !$timed_out, 'get_file_flags on a reader-less fifo returns instead of blocking';

  }
}

#-------------------------------------------------------------------------------
# The restore path. FS_IOC_SETFLAGS is unsupported on overlayfs (Docker's
# default storage driver) and on tmpfs, and the owner-settable flags are the
# only ones reachable without CAP_LINUX_IMMUTABLE, so this is skipped rather
# than assumed. The privileged variants belong to tier 3.

SKIP: {

  skip 'FS_IOC_GETFLAGS unsupported on this filesystem', 5
    if !$supported;

  my $target = File::Spec->catfile( $tmp, 'settable' );

  open my $out, '>', $target or die "create $target: $!";
  print { $out } "x\n";
  close $out;

  my $before = $get_file_flags->( $target );

  # FS_NODUMP_FL: in FS_FL_USER_MODIFIABLE, so the file's owner may set it.
  my $nodump = 0x00000040;

  skip 'FS_IOC_SETFLAGS is not supported here', 5
    if !defined $set_file_flags->( $target, $before | $nodump );

  my $after = $get_file_flags->( $target );

  ok defined $after, 'flags still readable after a set';

  is( ( $after & $nodump ), $nodump, 'set_file_flags applied the requested bit' );

  # The point of the read-only mask: a snapshot never carries these bits, and
  # restoring must leave whatever the file has now rather than clearing them.
  # On ext4 that is FS_EXTENT_FL, which every file has.
  my $readonly_before = $before & $pkg->FS_READONLY_FLAGS;

  SKIP: {

    skip 'this file carries no read-only flags to preserve', 2
      if !$readonly_before;

    # Restore exactly what get_metadata_from_system would have stored: the
    # current flags with the read-only bits stripped out.
    my $snapshot = $before & ~$pkg->FS_READONLY_FLAGS & 0xffffffff;

    ok defined $set_file_flags->( $target, $snapshot ), 'restoring a stripped snapshot succeeds';

    is( ( $get_file_flags->( $target ) & $pkg->FS_READONLY_FLAGS ), $readonly_before,
      'read-only flags are preserved, not cleared, by the restore' );

  }

  # Put it back so the tempdir cleanup is not fighting a flag.
  $set_file_flags->( $target, $before & ~$pkg->FS_READONLY_FLAGS & 0xffffffff );

  is( ( $get_file_flags->( $target ) & $nodump ), 0, 'the bit can be cleared again' );

}

#-------------------------------------------------------------------------------

sub _find_in_path {

  my ( $name ) = @_;

  for my $dir ( File::Spec->path(), '/sbin', '/usr/sbin' ) {

    my $candidate = File::Spec->catfile( $dir, $name );

    return $candidate if -x $candidate;

  }

  return;

}

# lsattr -d prints a flag-letter field; map the letters back to bit values so
# the comparison is against the tool rather than against our own arithmetic.

sub _lsattr_flags {

  my ( $lsattr, $file ) = @_;

  my %bit = (
    s => 0x00000001, u => 0x00000002, c => 0x00000004, S => 0x00000008,
    i => 0x00000010, a => 0x00000020, d => 0x00000040, A => 0x00000080,
    E => 0x00000800, I => 0x00001000, j => 0x00004000, t => 0x00008000,
    D => 0x00010000, T => 0x00020000, h => 0x00040000, e => 0x00080000,
    V => 0x00100000, C => 0x00800000, x => 0x02000000, N => 0x10000000,
    P => 0x20000000, F => 0x40000000,
  );

  my ( $out, undef, $status ) = capture( $lsattr, '-d', '--', $file );

  return if $status != 0;

  my ( $letters ) = $out =~ /\A(\S+)/
    or return;

  my $flags = 0;

  for my $letter ( split //, $letters ) {

    next if $letter eq '-';

    return if !exists $bit{ $letter };  # an unknown letter would give a wrong answer

    $flags |= $bit{ $letter };

  }

  return $flags;

}

done_testing();
