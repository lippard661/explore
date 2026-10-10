package Explore::Builtins;
use strict;
use warnings;
use Fcntl qw(:flock O_RDONLY O_WRONLY O_RDWR O_CREAT O_EXCL O_APPEND O_TRUNC);
our $VERSION = '1.3';

# O_NOFOLLOW where the platform has it (Linux/*BSD/OpenBSD/macOS); 0 elsewhere.
# Used so file operations in a shared, possibly world-writable game directory
# refuse a planted symlink at the target instead of following it.
use constant O_NOFOLLOW_ => do { my $v = eval { Fcntl::O_NOFOLLOW() }; defined $v ? $v : 0 };

# ============================================================================
#  Explore::Builtins -- the Explore-specific NATIVE builtins (replacements for
#  the helpers that were PL/I on Multics because BASIC could not do the job).
#  Registered into a MBasic::Registry; the generic core knows none of these.
#
#  Calling convention (from MBasic::Registry / MBasic::Arg):
#     $code->($ctx, \@args)
#   where each @arg supports ->get (read) and ->set($v) (write-back to the
#   caller's variable, for out-parameters).  $ctx = { rs, interp, out }.
#
#  These mostly REPLACE Multics machinery with its simpler Unix equivalent:
#     exp_home_    -> $ENV{HOME} / getpwuid          (was user_info_$homedir)
#     exp_getpw_   -> un-echoed read via stty        (was read_password_)
#     exp_canwrite_-> -w file test                   (was hcs_$get_user_effmode)
#     exp_lock_    -> flock(LOCK_EX|LOCK_NB)          (was set_lock_$lock)
#     exp_unlock_  -> flock(LOCK_UN) / close          (was set_lock_$unlock)
#     quit_off/on  -> $SIG{INT} handling             (was ios_$order quit_...)
#
#  PATH TRANSLATION: the game builds Multics pathnames ">a>b>c".  On Unix we
#  translate '>' to '/'.  A leading '>' becomes an absolute path anchored at a
#  configurable root (default: the current working directory), so the game's
#  ">site>explore_dir>..." maps under a real Unix directory the installer set.
# ============================================================================

our $ROOT = '.';      # Unix root the Multics '>' hierarchy maps under
our %LOCKS;           # path -> open filehandle currently held (for unlock)

# Prefix substitutions: an ordered list of [ multics_prefix => unix_path ]
# pairs applied (longest-prefix first) BEFORE the general '>'-to-'/' mapping.
# This lets the deployer map, e.g., ">site>explore_dir" to a real Unix
# location like "/usr/local/share/explore" without editing the BASIC source.
# Configure via Explore::Builtins::add_prefix($multics, $unix) or by setting
# @PREFIX_MAP directly.  Empty by default (falls back to $ROOT anchoring).
our @PREFIX_MAP;

sub add_prefix {
    my ($multics, $unix) = @_;
    push @PREFIX_MAP, [ $multics, $unix ];
    # keep longest multics-prefix first so the most specific match wins
    @PREFIX_MAP = sort { length($b->[0]) <=> length($a->[0]) } @PREFIX_MAP;
    return;
}
sub clear_prefixes { @PREFIX_MAP = (); return; }

# translate a Multics pathname to a Unix path.  '>' is the Multics path
# separator (like Unix '/'); the game concatenates it in the middle of paths
# (e.g. w9$ & ">hours.data").  Resolution order:
#   1. try each configured prefix substitution (longest first): if the path
#      starts with a Multics prefix, replace it with the Unix path, then
#      convert any remaining '>' to '/'.
#   2. otherwise, a leading '>' is a Multics-absolute path anchored under $ROOT.
#   3. otherwise, just convert every '>' to '/' (relative paths, or a Unix path
#      that has interior '>' from concatenation).
sub mult_path {
    my ($p) = @_;

    # CONTAINMENT (this is the pathxlate boundary MBasic's SECURITY section
    # names): refuse parent-directory traversal so a path built from
    # player-controlled text (abbrev names, etc.) cannot escape the mapped
    # subtree.  Multics has no ".." (its parent operator is "<"); the game
    # never uses either, so any occurrence is a bug or an escape attempt.
    if ($p =~ m{(?:\A|[>/])\.\.(?:[>/]|\z)} || $p =~ /</) {
        die "Invalid pathname (path traversal not allowed): $p\n";
    }
    # A NUL would otherwise travel on to sysopen and stat, which merely warn
    # about it -- "Invalid \0 character in pathname for ftfile: ..." -- spilling
    # the interpreter's own source file and line numbers onto the player's
    # screen and then failing obscurely.  (Not interpolated: it has a NUL in
    # it.)
    if ($p =~ /\0/) {
        die "Invalid pathname (embedded null character)\n";
    }

    return $p unless $p =~ />/;           # no '>' anywhere -> already Unix

    # 1. configured prefix substitutions (longest match first)
    for my $pair (@PREFIX_MAP) {
        my ($mprefix, $upath) = @$pair;
        if ($p eq $mprefix) {             # exact match
            return $upath;
        }
        if (index($p, $mprefix . '>') == 0) {   # prefix followed by a separator
            my $rest = substr($p, length($mprefix));   # includes leading '>'
            $rest =~ s{>}{/}g;
            $upath =~ s{/$}{};
            return $upath . $rest;        # $rest starts with '/'
        }
    }

    # 2. Multics-absolute -> anchor under ROOT
    if ($p =~ /^>/) {
        $p =~ s{^>}{};
        $p =~ s{>}{/}g;
        my $base = $ROOT; $base =~ s{/$}{};
        return "$base/$p";
    }

    # 3. relative / Unix-with-interior-'>' -> just convert separators
    $p =~ s{>}{/}g;
    return $p;
}

sub register_all {
    my ($registry) = @_;

    # --- helpers that were PL/I on Multics (must be native) ---
    $registry->register('exp_home_',     \&exp_home_);
    $registry->register('exp_getpw_',    \&exp_getpw_);
    $registry->register('exp_canwrite_', \&exp_canwrite_);
    $registry->register('exp_lock_',     \&exp_lock_);
    $registry->register('exp_unlock_',   \&exp_unlock_);

    # --- quit_off / quit_on -> SIGINT control ---
    $registry->register('quit_off',      \&quit_off);
    $registry->register('quit_on',       \&quit_on);

    # --- Multics command stubs (mapped to Unix equivalents) ---
    $registry->register('do',            \&cmd_do);           # command execution
    $registry->register('create',        \&cmd_create);       # touch (empty file)
    $registry->register('delete_force',  \&cmd_delete_force); # unlink
    $registry->register('sort_seg',      \&cmd_sort_seg);     # sort file in place
    $registry->register('send_message',  \&cmd_send_message); # Unix `write`
    $registry->register('abc',           \&cmd_abc);          # adjust_bit_count -> no-op
    $registry->register('ted',           \&cmd_ted);          # editor: $EDITOR/ed/vi

    return;
}

# ---- exp_home_(h$) : write the user's home directory into h$ ----
# The game concatenates ">start_up.explore", the abbrev files, etc. onto h9$
# and opens the result through mult_path.  We set h9$ to the player's real Unix
# home directory: h9$ & ">file" then becomes "/home/you>file", which mult_path
# (rule 3) turns into "/home/you/file".  This is what the README promises --
# per-user files (saved games, abbrevs, start_up.explore) live in the player's
# home.  (The earlier '' made every such path resolve to the filesystem root,
# where a normal user cannot write, so the whole abbreviation feature silently
# no-opped.)  If no home is discoverable we fall back to $ROOT.
sub exp_home_ {
    my ($ctx, $args) = @_;
    my $home = $ENV{HOME};
    $home = (getpwuid($<))[7] if !defined $home || $home eq '';
    $home = $ROOT             if !defined $home || $home eq '';
    $home =~ s{/+$}{} unless $home eq '/';   # no trailing slash
    $args->[0]->set($home);
    return;
}

# ---- exp_canwrite_(path$, flag) : flag = 1 if writable, 0 if not ----
sub exp_canwrite_ {
    my ($ctx, $args) = @_;
    my $path = mult_path($args->[0]->get);
    my $writable = (-e $path) ? (-w $path ? 1 : 0)
                              : ( -w _dirname($path) ? 1 : 0 );  # can create?
    $args->[1]->set($writable);
    return;
}
sub _dirname { my $p = shift; $p =~ s{/[^/]*$}{}; $p eq '' ? '.' : $p; }

# ---- exp_lock_(path$, room, status) : 1=acquired, 0=busy, -1=error ----
# Uses flock advisory locking, held across the caller's critical section; the
# lock is released by exp_unlock_ (or on process exit).  Pre-check writability
# to avoid the "can't lock a read-only file" fault-equivalent (return -1).
sub exp_lock_ {
    my ($ctx, $args) = @_;
    my $path = mult_path($args->[0]->get);
    # already holding this lock in THIS process?  Re-locking is a no-op success;
    # do not reopen (that would leak the first handle and lose the lock on the
    # subsequent close).
    if ($LOCKS{$path}) { $args->[2]->set(1); return; }
    # write-access pre-check: no write => cannot lock => give up (-1)
    my $can = (-e $path) ? (-w $path) : (-w _dirname($path));
    unless ($can) { $args->[2]->set(-1); return; }
    my $fh;
    # O_NOFOLLOW refuses a planted symlink at the lock path.  A lock file lives
    # in the shared data directory and must be writable by the next player, so
    # widen the umask for just this create: the runner no longer carries a
    # process-wide 0002 (which also loosened the player's own private files),
    # and without this a 0022 player would create the lock 0644 and lock
    # everyone else out.
    my $oldmask = umask 0002;
    my $opened  = sysopen($fh, $path, O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW_, 0666);
    umask $oldmask if defined $oldmask;
    unless ($opened) {
        $args->[2]->set(-1); return;
    }
    if (flock($fh, LOCK_EX | LOCK_NB)) {
        $LOCKS{$path} = $fh;                 # hold the lock (and the handle)
        $args->[2]->set(1);                  # acquired
    } else {
        close $fh;
        $args->[2]->set(0);                  # busy (another process holds it)
    }
    return;
}

# ---- exp_unlock_(path$) : release the lock ----
sub exp_unlock_ {
    my ($ctx, $args) = @_;
    my $path = mult_path($args->[0]->get);
    if (my $fh = delete $LOCKS{$path}) {
        flock($fh, LOCK_UN);
        close $fh;
    }
    return;
}

# ---- exp_getpw_(prompt$, word$) : un-echoed read of the sorcerer word ----
sub exp_getpw_ {
    my ($ctx, $args) = @_;
    my $prompt = $args->[0]->get;
    # print the prompt (no newline), read a line with echo off
    ($ctx->{out} || sub { print $_[0] })->($prompt);
    my $word = _read_noecho();
    # End of input is not an empty word.  The game retries for as long as the
    # word is empty (explore.basic 9770-9810), so handing back '' here spun the
    # prompt forever once stdin closed -- silently, since the prompt is written
    # without a newline.  MBasic's LINPUT ends the run in the same situation and
    # in the same words.
    die "Not enough input, add more\n" unless defined $word;
    $args->[1]->set($word);
    return;
}
# Returns undef at end of input, which the caller must not confuse with an
# empty line; see exp_getpw_ above.
sub _read_noecho {
    my $line;
    if (-t STDIN) {
        if (system('stty', '-echo') == 0) {
            # Guarantee echo is turned back ON even if the read dies (MBasic 1.1
            # can die mid-prompt on a run-time error), so we never strand the
            # player's terminal with echo off.
            my $ok = eval { $line = <STDIN>; 1 };
            system('stty', 'echo');
            print "\n";
            die $@ if !$ok;                 # re-raise AFTER restoring the terminal
        } else {
            # Could not disable echo: warn rather than silently echoing the
            # (admittedly rot13, non-secret) word, then read it visibly.
            warn "explore: could not disable terminal echo; input will be visible\n";
            $line = <STDIN>;
            print "\n";
        }
    } else {
        $line = <STDIN>;                    # non-tty (tests / pipes): no echo issue
    }
    chomp $line if defined $line;
    return $line;
}

# ---- quit_off / quit_on : control the interrupt (break) key ----
# On Multics these disable/enable the quit key via ios_$order.  On Unix we
# manage $SIG{INT}: quit_off installs a handler that returns to the game's
# command prompt (rather than killing the process); quit_on restores default.
# The RunState can carry an 'on_interrupt' target; for now quit_off simply
# IGNOREs SIGINT (break does nothing) and quit_on restores default -- matching
# the game's "^quit disables the break key" semantics.  (A return-to-prompt
# handler can be wired via the run loop later.)
sub quit_off { my ($ctx,$args)=@_; $SIG{INT} = 'IGNORE'; return; }
sub quit_on  { my ($ctx,$args)=@_; $SIG{INT} = 'DEFAULT'; return; }

# ============================================================================
#  Multics command stubs -> Unix equivalents.
#  Each is called as  call "name": arg1, arg2, ...  where the args are the
#  command's arguments (strings).  Args that are Multics pathnames go through
#  mult_path.  Multics command flags (like "-brief") are ignored on Unix.
# ============================================================================

# ---- _run_child(@argv) : run an external program on the player's terminal ----
#
# Two things the old backticks got wrong, both fixed by handing the child the
# terminal instead of a capture buffer:
#
#   * `$cmd 2>&1` accumulated the WHOLE output in memory before the player saw
#     any of it, so a command with unbounded output ("..yes", "..cat" of
#     something large, "..find /") ended the session with "Out of memory!" --
#     reachable by accident, not just deliberately.  Now output streams, and
#     a pager or an editor behaves as it should.
#
#   * SIGINT.  quit_off installs SIG_IGN, and an ignored disposition survives
#     execve, so under ^quit mode a command inherited the ignore and could not
#     be interrupted at all.  The child now gets the default disposition back
#     while the game ignores SIGINT for as long as the child runs.  Both are in
#     the same foreground process group, so one ^C reaches both: the command
#     dies, the game does not, and the player is returned to the game's command
#     line.  That needs no job control and no tcsetpgrp.  Afterwards the game's
#     own disposition -- whichever of quit_off/quit_on last set it -- is
#     restored, so ^quit still disables break for the game itself.
sub _run_child {
    my ($ctx, @argv) = @_;
    return unless @argv && defined $argv[0] && length $argv[0];
    my $prev_int  = $SIG{INT};
    my $prev_quit = $SIG{QUIT};
    $SIG{INT} = $SIG{QUIT} = 'IGNORE';
    my $pid = fork;
    if (!defined $pid) {
        warn "explore: cannot run $argv[0]: fork failed: $!\n";
    }
    elsif (!$pid) {                       # child
        $SIG{INT} = $SIG{QUIT} = 'DEFAULT';
        exec { $argv[0] } @argv;
        warn "explore: cannot execute $argv[0]: $!\n";
        # _exit, not exit: END blocks belong to the parent (File::Temp would
        # unlink the read-only rwdir file the parent is still using).
        eval { require POSIX; POSIX::_exit(127); 1 } or CORE::exit(127);
    }
    else {
        while (1) {                       # wait, without tripping over EINTR
            my $r = waitpid($pid, 0);
            last if $r == $pid || $r == -1;
        }
    }
    $SIG{INT}  = defined $prev_int  ? $prev_int  : 'DEFAULT';
    $SIG{QUIT} = defined $prev_quit ? $prev_quit : 'DEFAULT';
    return;
}

# do "command line"  -> execute a shell command (the .. / m command escape)
sub cmd_do {
    my ($ctx, $args) = @_;
    my $cmd = $args->[0]->get;
    return unless defined $cmd && $cmd =~ /\S/;
    _run_child($ctx, '/bin/sh', '-c', $cmd);
    return;
}

# create "path"  -> touch (create an empty file if absent)
sub cmd_create {
    my ($ctx, $args) = @_;
    my $path = mult_path($args->[0]->get);
    # O_CREAT|O_EXCL creates only when absent (no TOCTOU between -e and open) and
    # O_NOFOLLOW refuses a planted symlink; an already-present file (EEXIST) or
    # any other failure is ignored, as before.
    if (sysopen(my $fh, $path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW_, 0666)) {
        close $fh;
    }
    return;
}

# delete_force "path" [,"-brief"]  -> unlink
sub cmd_delete_force {
    my ($ctx, $args) = @_;
    my $path = mult_path($args->[0]->get);
    unlink $path if -e $path;      # -brief and other flags ignored
    return;
}

# sort_seg "path" [,"-replace"]  -> sort the file's lines, atomically
sub cmd_sort_seg {
    my ($ctx, $args) = @_;
    my $path = mult_path($args->[0]->get);
    return unless -f $path;
    # O_NOFOLLOW: don't read/write through a planted symlink.
    sysopen(my $in, $path, O_RDONLY | O_NOFOLLOW_) or return;
    my @lines = <$in>; close $in;
    @lines = sort @lines;
    # write a temp beside the file and rename, so a crash mid-sort cannot lose
    # the file (the old in-place truncate-then-write could).
    my $tmp = _dirname($path) . "/.exp_sort.$$";
    sysopen(my $out, $tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW_, 0666) or return;
    print $out @lines or do { close $out; unlink $tmp; return; };
    close $out or do { unlink $tmp; return; };
    if (my @st = stat $path) { chmod $st[2] & 07777, $tmp; }  # preserve mode
    rename($tmp, $path) or do { unlink $tmp; return; };
    return;
}

# send_message "user" [, "text"]  -> Unix `write` to another logged-in user
#
# The game calls this with the RECIPIENT ONLY (explore.basic 15820:
# call "send_message": y1$), because on Multics send_message then entered input
# mode and read the message from the terminal.  Piping it the absent second
# argument therefore sent a bare newline, and the "send" command could never
# deliver anything at all.  With no text argument we now hand `write` the
# terminal, which reads the message the same way Multics did; a caller that does
# supply the text still gets the non-interactive pipe.
sub cmd_send_message {
    my ($ctx, $args) = @_;
    my $user = defined $args->[0] ? $args->[0]->get : undef;
    return unless defined $user && $user =~ /\S/;
    # Multics addressed people as Person.Project.  Unix has no project, so if
    # the whole string is not a login but the part before the first dot is,
    # send to that.
    if (!defined getpwnam($user)) {
        my ($person) = split /\./, $user, 2;
        $user = $person if defined $person && length $person
                        && defined getpwnam($person);
    }
    if (defined $args->[1]) {
        my $text = $args->[1]->get;
        # `write` may refuse and exit at once (recipient not logged in, mesg n),
        # which would leave this print writing to a pipe with no reader.
        local $SIG{PIPE} = 'IGNORE';
        if (open my $w, '|-', 'write', $user) {
            print $w (defined $text ? $text : ''), "\n";
            close $w;
        }
        return;
    }
    _run_child($ctx, 'write', $user);
    return;
}

# abc "path"  (adjust_bit_count)  -> NO-OP on Unix.
# On Multics this forced a segment's bit-count to match its content so external
# readers could see buffered writes.  Unix file length follows bytes already,
# and the interpreter flushes eagerly, so there is nothing to adjust.
sub cmd_abc { my ($ctx,$args)=@_; return; }

# ted "-pathname", "path"  (or "path")  -> invoke a text editor
#   Multics invocation seen: call "ted": "-pathname", <path>
sub cmd_ted {
    my ($ctx, $args) = @_;
    # find the path argument (skip a leading "-pathname" flag)
    my @a = map { $_->get } @$args;
    my ($path) = grep { $_ !~ /^-/ } @a;
    return unless defined $path;
    $path = mult_path($path);
    # $EDITOR commonly carries arguments ("vim -u NONE", "emacs -nw").  Passing
    # the whole string as the program name tried to execute a file of that
    # literal name and silently failed, so split it into words.
    my @editor = defined $ENV{EDITOR} ? split(' ', $ENV{EDITOR}) : ();
    @editor = (_first_in_path('ed','vi') || 'ed') unless @editor;
    _run_child($ctx, @editor, $path);
    return;
}
sub _first_in_path {
    for my $prog (@_) {
        for my $d (split /:/, ($ENV{PATH}||'')) {
            return $prog if -x "$d/$prog";
        }
    }
    return undef;
}

1;

__END__

=head1 NAME

Explore::Builtins - native (Perl) builtins and command stubs for the Explore game

=head1 SYNOPSIS

    use MBasic::Registry;
    use Explore::Builtins;

    my $registry = MBasic::Registry->new;
    Explore::Builtins::register_all($registry);

    $Explore::Builtins::ROOT = '/';                    # anchor for '>' paths
    Explore::Builtins::add_prefix('>site>explore_dir', '/usr/local/share/explore');

=head1 DESCRIPTION

This module supplies the Explore-specific native builtins that the game's BASIC
source calls -- the operations that were written in PL/I on Multics because
BASIC could not perform them -- plus the Multics command stubs, each mapped to
its Unix equivalent.  It also provides Multics-to-Unix pathname translation.

The L<MBasic> interpreter core knows nothing about Explore; registering these
builtins is what makes it run I<this> game.

=head1 FUNCTIONS

=head2 register_all($registry)

Register every Explore builtin and command stub into an L<MBasic::Registry>.

The registered builtins, and the Multics facility each replaces:

=over 4

=item exp_home_   -- home directory (was user_info_$homedir)

=item exp_getpw_  -- un-echoed prompt read (was read_password_)

=item exp_canwrite_ -- write-access test, via C<-w> (was hcs_$get_user_effmode)

=item exp_lock_ / exp_unlock_ -- advisory locking via C<flock> (was set_lock_)

=item quit_off / quit_on -- interrupt control via C<$SIG{INT}> (was ios_$order)

=item do -- run a shell command; create -- touch; delete_force -- unlink;
sort_seg -- sort a file in place; send_message -- Unix C<write>; ted -- invoke
C<$EDITOR> (else C<ed>/C<vi>); abc (adjust_bit_count) -- a no-op, since Unix
file lengths follow their bytes.

=back

=head2 add_prefix($multics_prefix, $unix_path)

Register a pathname prefix substitution.  A Multics path beginning with
C<$multics_prefix> (optionally followed by more C<< > >> components) is rewritten
to C<$unix_path>.  Substitutions are tried longest-prefix-first.

=head2 clear_prefixes

Remove all registered prefix substitutions.

=head2 mult_path($path)

Translate a Multics pathname to a Unix path: apply the configured prefix
substitutions, then anchor a leading C<< > >> under C<$Explore::Builtins::ROOT>,
and convert any remaining C<< > >> separators to C</>.  Paths with no C<< > >>
are returned unchanged.  This is passed to the interpreter as its
C<pathxlate> hook.

=head1 PACKAGE VARIABLES

=over 4

=item $Explore::Builtins::ROOT

The Unix directory under which a Multics-absolute C<< > >> path (not covered by
a prefix substitution) is anchored.  Default C<.>.

=item @Explore::Builtins::PREFIX_MAP

The ordered list of C<[ multics_prefix =E<gt> unix_path ]> substitutions;
normally managed via C<add_prefix>.

=back

=head1 SEE ALSO

L<MBasic>, and the C<explore> program in this distribution.

=head1 AUTHOR

Jim Lippard <lippard@discord.org>

=head1 LICENSE

Copyright (c) 2026 Jim Lippard.  Free software under the BSD 3-Clause License.

=cut
