use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib"; use lib ($ENV{MBASIC_LIB} // ());
use Test::More;
use File::Temp qw(tempdir);
use MBasic::Interp; use MBasic::Registry;
use Explore::Builtins;
use POSIX ();

# Regression tests for the third review pass: crashes, hangs and permission
# problems in the runner and in its interaction with the interpreter.

my $dir = tempdir(CLEANUP => 1);
$Explore::Builtins::ROOT = $dir;

sub run {
    my ($lines, %opt) = @_;
    my $reg = MBasic::Registry->new;
    Explore::Builtins::register_all($reg);
    my $interp = MBasic::Interp->new(registry => $reg, %opt);
    $interp->load_helper_lines($lines, 'MAIN');
    $interp->{main} = $interp->{programs}{'MAIN'};
    my $out = '';
    $interp->run(out => sub { $out .= $_[0] }, %opt);
    return $out;
}

# Capture the process's STDOUT by file descriptor, so a child's output counts.
sub capturing_stdout {
    my ($file, $code) = @_;
    open my $save, '>&', \*STDOUT or die "dup STDOUT: $!";
    open STDOUT, '>', $file       or die "redirect STDOUT: $!";
    my $ok = eval { $code->(); 1 }; my $err = $@;
    open STDOUT, '>&', $save      or die "restore STDOUT: $!";
    close $save;
    die $err unless $ok;
    open my $r, '<', $file or return '';
    local $/; my $got = <$r>; close $r;
    return defined $got ? $got : '';
}

my $runner  = "$FindBin::Bin/../explore";
my $share   = "$FindBin::Bin/../share";
my @inc     = ('-I', "$FindBin::Bin/../lib");
push @inc, ('-I', $ENV{MBASIC_LIB}) if $ENV{MBASIC_LIB};

# Run the runner as a child process, under a deadline, and never hang.
#
# The tests below that need a whole game session must not be able to stop
# "make test", whatever is installed.  That is not hypothetical: on MBasic 1.3
# the game's command loop spins at its prompt forever once its input is
# exhausted -- the bug MBasic 1.4 fixes -- so a session ended by closing stdin
# never returns.  These sessions are therefore ended with a "quit" command
# rather than by exhausting the input, and the deadline is a backstop that
# turns any future hang into a failed test instead of a stuck suite.
#
# Returns ($exited_on_its_own, $combined_output).
sub run_runner {
    my (%a) = @_;
    my $log = $a{log} || "$dir/runner.log";
    my $in  = $a{input};
    if (defined $in) {
        my $f = "$dir/runner.in";
        open my $w, '>', $f or die "write $f: $!"; print $w $in; close $w;
        $in = $f;
    }
    my $pid = fork;
    die "fork: $!" unless defined $pid;
    unless ($pid) {
        chdir $a{cwd} if defined $a{cwd};
        $ENV{HOME} = $a{home} if defined $a{home};
        umask $a{umask} if defined $a{umask};
        open STDIN,  '<', (defined $in ? $in : '/dev/null');
        open STDOUT, '>', $log;
        open STDERR, '>&', \*STDOUT;
        exec $^X, @inc, $runner, @{ $a{args} || [] };
        POSIX::_exit(127);
    }
    my $deadline = time + ($a{timeout} || 60);
    my $exited = 0;
    while (1) {
        my $r = waitpid($pid, POSIX::WNOHANG());
        if ($r == $pid || $r == -1) { $exited = 1; last }
        last if time >= $deadline;
        select undef, undef, undef, 0.05;
    }
    unless ($exited) { kill 'KILL', $pid; waitpid $pid, 0; }
    my $out = '';
    if (open my $r, '<', $log) { local $/; $out = <$r> // ''; close $r; }
    unlink $log;
    return ($exited, $out);
}

# ==== R3-1: end of input must not become an endless empty word ==============
# The game retries the sorcerer prompt for as long as the word is empty
# (explore.basic 9770-9810), so returning '' at end of input span the prompt
# forever, silently -- the prompt carries no newline.
{
    # Reopen the DESCRIPTOR, not just the glob: _read_noecho tests -t STDIN and
    # reads <STDIN>, and the harness may hand this test a terminal or a pipe
    # that never closes, either of which would block here rather than reach
    # end of input.  Restored from a saved dup afterwards.
    open my $save_in, '<&', \*STDIN  or plan skip_all => 'cannot dup STDIN';
    open STDIN, '<', '/dev/null'     or plan skip_all => 'no /dev/null';
    my $writes = 0;
    my $ok = eval {
        run(['10 let q$ = "            "',
             '20 call "exp_getpw_": "Magic word, please:", q$',
             '30 if len(q$)=0 then 10',
             '40 print "accepted"', '50 end'],
            out => sub { die "SPUN\n" if ++$writes > 2000 });
        1;
    };
    my $err = $ok ? '' : $@;
    open STDIN, '<&', $save_in or die "restore STDIN: $!";
    close $save_in;
    unlike($err, qr/SPUN/, 'R3-1 exp_getpw_ at end of input does not spin');
    like($err, qr/Not enough input/,
         'R3-1 and reports the same condition MBasic uses for LINPUT');
}

# ==== R3-2: a NUL in a pathname is refused, not passed to sysopen ===========
# sysopen and stat only WARN about a NUL ("Invalid \0 character in pathname
# for ftfile: ..."), spilling the interpreter's own file and line numbers onto
# the player's screen.
{
    my $err = '';
    eval { Explore::Builtins::mult_path("a\0b.explore"); 1 } or $err = $@;
    like($err, qr/null character/, 'R3-2 a NUL in a pathname is refused');
    unlike($err, qr/traversal/, 'R3-2 with its own message, not the traversal one');
}

# ==== R3-3: a `do` child gets the default SIGINT back =======================
# quit_off installs SIG_IGN and an ignored disposition survives execve, so a
# command run under ^quit mode could not be interrupted at all.  The child
# signals itself: if SIGINT were still ignored it would survive and echo.
{
    my $sink = '';
    my $got = capturing_stdout("$dir/sig.out", sub {
        $sink = run(['10 call "quit_off"',
                     '20 call "do": "kill -INT $$; echo SURVIVED"',
                     '30 print "still playing"', '40 end']);
    });
    # look in BOTH places: the old code captured the child's output into the
    # interpreter's sink, so checking only the terminal would pass vacuously.
    unlike($got . $sink, qr/SURVIVED/,
           'R3-3 a do child is interruptible even after quit_off');
    like($sink, qr/still playing/,
         'R3-3 and the game itself survives the interrupted child');
}

# ==== R3-4: `do` streams, rather than accumulating the whole output =========
# The old backticks buffered everything before the player saw any of it, so a
# command with unbounded output ended the session with "Out of memory!".  A
# bounded stand-in: the output must not come back through the sink at all.
{
    my $sink;
    my $got = capturing_stdout("$dir/stream.out", sub {
        $sink = run(['10 call "do": "echo STREAMED"', '20 end']);
    });
    like($got,   qr/STREAMED/, 'R3-4 do output reaches the terminal');
    unlike($sink, qr/STREAMED/,
           'R3-4 and is not accumulated in the interpreter output sink');
}

# ==== R3-5: $EDITOR with arguments is split into words ======================
{
    my $log = "$dir/ted.log";
    my $fake = "$dir/fake_editor";
    open my $fh, '>', $fake or die; print $fh <<"ED"; close $fh;
#!/bin/sh
echo "\$@" >> "$log"
ED
    chmod 0755, $fake;
    local $ENV{EDITOR} = "$fake -flag";
    run(['10 call "ted": "-pathname", ">edited_file"', '20 end']);
    my $got = ''; if (open my $r, '<', $log) { local $/; $got = <$r>; close $r; }
    like($got, qr/-flag/,        'R3-5 an $EDITOR argument is passed through');
    like($got, qr/edited_file/,  'R3-5 and the pathname reaches the editor');
}

# ==== R3-6: a missing option argument is refused, not left undefined ========
SKIP: {
    skip 'runner not found', 1 unless -f $runner;
    for my $opt (qw(--share --var --basic --helpers --root --prefix)) {
        my (undef, $err) = run_runner(args => [$opt], timeout => 30);
        like($err, qr/option \Q$opt\E requires an argument/,
             "R3-6 $opt with no value is refused cleanly");
        unlike($err, qr/uninitialized value/,
               "R3-6 $opt does not leak uninitialized-value warnings");
    }
    # an empty Multics prefix would match every absolute path
    my (undef, $err) = run_runner(args => ['--prefix', '=/tmp'], timeout => 30);
    like($err, qr/bad --prefix/, 'R3-6 an empty --prefix prefix is refused');
}

# ==== R3-7: seeding the data directory does not follow a planted symlink ====
SKIP: {
    skip 'runner not found', 2 unless -f $runner;
    skip 'symlinks unsupported', 2 unless eval { symlink('', "$dir/.probe"); 1 };
    unlink "$dir/.probe";
    my $var    = "$dir/vardir";    mkdir $var;
    my $target = "$dir/outside_the_var_dir";
    # a DANGLING symlink: -e reads it as absent, so the old "!-e $dst" test
    # passed and File::Copy wrote straight through the link, creating a file
    # outside the shared directory as the player.
    symlink($target, "$var/hours.data") or skip 'cannot symlink', 2;
    my $home = "$dir/home"; mkdir $home;
    my $play = "$dir/play"; mkdir $play;
    my ($exited) = run_runner(cwd => $play, home => $home, input => "quit\nyes\n",
                              args => ['--share', $share, '--var', $var]);
    ok(!-e $target, 'R3-7 seeding does not write through a planted symlink');
    ok(-f "$var/winners.data",
       'R3-7 the unplanted master is still seeded, as a regular file');
}

# ==== R3-8: a player's own files keep the player's umask ====================
# The runner used to set umask 0002 process-wide, which also loosened saved
# games and the abbrev file.  On a system whose users share a default group
# (staff, on macOS) that made them writable by every other local user.
SKIP: {
    skip 'runner not found', 1 unless -f $runner;
    my $home = "$dir/home2"; mkdir $home;
    my $play = "$dir/play2"; mkdir $play;
    # Force read-only play -- no shared directory in use, so the player's own
    # umask must be honored.  The var path is placed UNDER A REGULAR FILE, so
    # make_path fails with ENOTDIR whoever runs the test; a mode-based
    # unwritable directory would not stop root.
    my $blocker = "$dir/a_file_not_a_dir";
    open my $bf, '>', $blocker or skip 'cannot create blocker', 1; close $bf;
    run_runner(cwd => $play, home => $home, umask => 0022,
               input => "save private_game\nquit\nyes\n",
               args => ['--share', $share, '--var', "$blocker/nope"]);
    my $saved = "$play/private_game.explore";
    SKIP: {
        skip 'the save did not happen in this environment', 1 unless -e $saved;
        my $mode = (stat $saved)[2] & 07777;
        ok(!($mode & 0020),
           sprintf('R3-8 a saved game keeps the player umask 0022 (got %04o)', $mode));
    }
}

done_testing;
