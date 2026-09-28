use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
use Test::More;
use File::Find;

# MANIFEST decides what "make dist" ships, and nothing else checks it: a file
# missing from MANIFEST is simply left out of the tarball, silently, and a
# file listed but absent only draws a "not found" murmur that does not fail
# the build.  The companion MBasic distribution shipped a release with no
# README and two test files missing that way, with the reduced suite still
# passing, which is what this guards against here.
#
# Core-only, and it works the same in a git checkout or an unpacked tarball.

my $root = "$FindBin::Bin/..";
chdir $root or plan skip_all => "cannot chdir to $root";
plan skip_all => 'no MANIFEST' unless -f 'MANIFEST';

# MANIFEST format: filename, optionally followed by whitespace and a comment.
my %listed;
open my $fh, '<', 'MANIFEST' or die "MANIFEST: $!";
while (<$fh>) {
    next if /^\s*#/ or /^\s*$/;
    my ($f) = /^(\S+)/ or next;
    $listed{$f} = 1;
}
close $fh;

# MakeMaker generates these into the dist directory; they are correctly
# listed but do not exist in a working tree.
my %generated = map { $_ => 1 } qw(META.yml META.json);

# 1. everything MANIFEST promises is really here
my @missing = grep { !$generated{$_} && !-e $_ } sort keys %listed;
is_deeply(\@missing, [], 'every file MANIFEST lists exists')
    or diag("MANIFEST lists these but they are not on disk:\n  ",
            join("\n  ", @missing));

# 2. every module and test on disk is promised
my @unlisted;
find(sub {
    return unless -f;
    return unless /\.(?:pm|t)\z/;
    my $rel = $File::Find::name;
    $rel =~ s{^\./}{};
    push @unlisted, $rel unless $listed{$rel};
}, 'lib', 't');
is_deeply([sort @unlisted], [], 'every .pm and .t on disk is in MANIFEST')
    or diag("present but not listed, so 'make dist' would omit them:\n  ",
            join("\n  ", sort @unlisted));

done_testing;
