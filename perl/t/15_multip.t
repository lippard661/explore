use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib"; use lib ($ENV{MBASIC_LIB} // ());
use Test::More;
use File::Temp qw(tempdir);
use Fcntl qw(:flock O_RDWR O_CREAT);
use POSIX ();
use Config;

# In multiplayer mode the game guards its shared files with advisory locks,
# acquired in BASIC at 4440/4740/4980 and released at 4548/4945/5079.  Three of
# those critical sections used to be left by a jump that skipped the release:
#
#   4550 goto 4640   (a player not yet listed in explore_usr)
#   5080 goto 5220   (no sorcerer message waiting -- the ORDINARY path)
#   11400 goto 11480 (logout, player not listed)
#
# so the first player to run any command kept explore_com.lock for the rest of
# the session and every other player span at 4990 at 100% CPU.  With two
# players each holding one lock and spinning for the other's, both wedged until
# one of them quit.
#
# The invariant this test pins: WHILE A PLAYER SITS AT ITS PROMPT IT MUST HOLD
# NO SHARED LOCK.  One player is enough to detect it -- the leak is not a race
# -- so this test needs no second user and no shared group.

my $runner = "$FindBin::Bin/../explore";
my $share  = "$FindBin::Bin/../share";
plan skip_all => 'runner or share directory not found'
    unless -f $runner && -d $share;
plan skip_all => 'no fork on this platform'
    unless $Config::Config{d_fork} || eval { my $p = fork; exit 0 unless $p; waitpid $p,0; 1 };

my $dir = tempdir(CLEANUP => 1);
my $var = "$dir/var";  mkdir $var or plan skip_all => "cannot create $var";
my $home = "$dir/home"; mkdir $home;
my $play = "$dir/play"; mkdir $play;

# Point the game's rwdir at our var directory and turn multiplayer on, by
# remapping just that one Multics pathname -- no need to copy the share tree.
my $rwdir = "$dir/rwdir";
open my $rw, '>', $rwdir or plan skip_all => "cannot write $rwdir";
print $rw "$var\nmultip\n"; close $rw;

my @inc = ('-I', "$FindBin::Bin/../lib");
push @inc, ('-I', $ENV{MBASIC_LIB}) if $ENV{MBASIC_LIB};

pipe(my $fromgame, my $tochild) or plan skip_all => 'no pipes';
pipe(my $fromparent, my $togame) or plan skip_all => 'no pipes';
my $pid = fork;
plan skip_all => 'cannot fork' unless defined $pid;
unless ($pid) {
    close $fromgame; close $togame;
    open STDIN,  '<&', $fromparent;
    open STDOUT, '>&', $tochild;
    open STDERR, '>&', $tochild;
    chdir $play;
    $ENV{HOME} = $home;
    exec($^X, @inc, $runner, '--share', $share, '--var', $var,
         '--prefix', ">site>explore_dir>explore.rwdir=$rwdir",
         '-modes', 'multip') or POSIX::_exit(127);
}
close $fromparent; close $tochild;
$togame->autoflush(1);

# Read for a while, without ever blocking forever.
sub sip {
    my ($secs) = @_;
    my $got = '';
    my $end = time + $secs;
    my $rin = ''; vec($rin, fileno($fromgame), 1) = 1;
    while (time < $end) {
        my $r = $rin;
        if (select($r, undef, undef, 0.2) > 0) {
            my $n = sysread($fromgame, my $b, 65536);
            last unless $n;
            $got .= $b;
        }
    }
    return $got;
}

my $banner = sip(15);
my $started = $banner =~ /clearing|shack|forest/;

# Is the lock file free?  A leaked flock is held by the game process, so our
# own LOCK_EX|LOCK_NB fails while it is idle at its prompt.
sub lock_is_free {
    my ($name) = @_;
    my $path = "$var/$name";
    return 1 unless -e $path;            # never created: certainly not held
    sysopen(my $fh, $path, O_RDWR | O_CREAT, 0666) or return 1;
    my $free = flock($fh, LOCK_EX | LOCK_NB) ? 1 : 0;
    flock($fh, LOCK_UN) if $free;
    close $fh;
    return $free;
}

SKIP: {
    skip 'the game did not start in this environment', 4 unless $started;

    print {$togame} "look\n";
    my $out = sip(15);
    like($out, qr/clearing|shack|forest|standing/,
         'a command is answered in multiplayer mode');

    # The player is now back at its prompt, holding nothing.
    for my $lock (qw(explore_usr.lock explore_com.lock explore_usr_com.lock)) {
        ok(lock_is_free($lock),
           "$lock is released while the player sits at its prompt");
    }
}

kill 'KILL', $pid; waitpid $pid, 0;
done_testing;
