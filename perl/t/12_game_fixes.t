use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib"; use lib ($ENV{MBASIC_LIB} // ());
use Test::More;
use File::Temp qw(tempdir);
use File::Copy;
use Cwd qw(getcwd);
use Time::Local qw(timelocal);

# Regression tests for three problems reported from a Windows port.

BEGIN {
    eval { require MBasic::Interp; require MBasic::Registry; 1 }
      or plan skip_all => 'MBasic interpreter not available';
}
require Explore::Builtins;
no warnings 'once';

my $share = "$FindBin::Bin/../share";
plan skip_all => "game data (share/) not found" unless -f "$share/explore.basic";

# Run a session.  %opt: argv, home, edit (coderef given the explore.data lines).
sub play {
    my (%opt) = @_;
    my $t = tempdir(CLEANUP => 1);
    for my $f (glob "$share/*") { my ($b) = $f =~ m{([^/]+)$}; copy($f, "$t/$b"); }
    if ($opt{edit}) {
        open my $in, '<', "$t/explore.data" or die $!;
        my @l = <$in>; close $in;
        $opt{edit}->(\@l);
        open my $o, '>', "$t/explore.data" or die $!; print $o @l; close $o;
    }
    open my $rw, '>', "$t/explore.rwdir" or die $!; print $rw "none\n"; close $rw;

    local $ENV{HOME} = $opt{home} // tempdir(CLEANUP => 1);
    $Explore::Builtins::ROOT = '/';
    Explore::Builtins::clear_prefixes();
    Explore::Builtins::add_prefix('>site>explore_dir', $t);

    my $reg = MBasic::Registry->new;
    Explore::Builtins::register_all($reg);
    $reg->register('set_acl', sub {}); $reg->register('exec_com', sub {});

    my $interp = MBasic::Interp->new(registry => $reg, search_path => [ $t ],
                                     argv => $opt{argv} || [],
                                     now  => timelocal(0, 0, 12, 9, 8, 2026)); # a Wednesday
    $interp->load_main("$t/explore.basic");
    $interp->load_all_helpers($t);

    my @input = (@{ $opt{input} }, 'quit', 'yes');
    my $out = '';
    eval {
        $interp->run(pathxlate => \&Explore::Builtins::mult_path,
                     out   => sub { $out .= $_[0] },
                     input => sub { die "out of input\n" unless @input; shift @input });
        1;
    } or $out .= "[died: $@]";
    return $out;
}

# --- "-abbrev NAME" survives the dim block (MBasic treats dim as a
#     declaration; executing it used to erase the loaded abbreviations, and
#     a file of more than ten entries faulted before that) ---
{
    my $home = tempdir(CLEANUP => 1);
    open my $a, '>', "$home/mine.explore_abbrev" or die $!;
    print $a "$_,a$_,what\n" for 1 .. 25;      # more than the default bound 10
    print $a "26,i,what\n";
    close $a;

    my $out = play(home => $home, argv => [ '-ab', "$home/mine" ], input => [ 'i' ]);
    unlike($out, qr/Subscript out of bounds/,
           '-ab with more than ten abbreviations does not fault');
    like($out, qr/carrying/i,
         '-ab abbreviation still defined after the dim block runs');
}

# --- "get all" ignores the invisible barrier markers (abyss/fissure/rock-1),
#     as a plain "get" already did ---
{
    # put one visible object and one invisible marker in the start room
    my $both = sub { my $l = shift;
        for (@$l) { s/^obelisk,16,/obelisk,51,/; s/^fissure,54,/fissure,51,/ } };
    my $out = play(edit => $both, input => [ 'get all', 'what' ]);
    my ($inv) = $out =~ /currently carrying:(.*?)\?/s;
    $inv = '' unless defined $inv;
    like($inv,   qr/obelisk/,  'get all still takes the visible object');
    unlike($inv, qr/fissure/,  'get all does not take an invisible marker');

    # A room holding nothing but a marker: the marker is still not taken.
    # (It reports nothing rather than "There is nothing here to get!" -- the
    # presence loop at 7240 is left alone deliberately, because guarding it
    # too would cost another forward reference and Multics BASIC allows only
    # about 100 in a program.  See the Changes entry.)
    my $marker = sub { my $l = shift; for (@$l) { s/^fissure,54,/fissure,51,/ } };
    my $out2 = play(edit => $marker, input => [ 'get all', 'what' ]);
    my ($inv2) = $out2 =~ /currently carrying:(.*?)\?/s;
    $inv2 = '' unless defined $inv2;
    unlike($inv2, qr/fissure/, 'get all in a marker-only room takes nothing');
}

# --- bare "save" / "restore" reach their handlers and use the default name ---
{
    my $cwd  = getcwd();
    my $work = tempdir(CLEANUP => 1);   # the save lands in the working directory
    chdir $work or die $!;

    my $out = play(input => [ 'n', 'save' ]);
    unlike($out, qr/I don't know the word/, 'bare "save" is not rejected');
    like($out, qr/saved/i, 'bare "save" reports the game saved');
    ok(-f "$work/SAVED_GAME_.explore", 'bare "save" uses the default name');

    my $back = play(input => [ 'restore' ]);
    unlike($back, qr/I don't know the word/, 'bare "restore" is not rejected');

    chdir $cwd or die $!;
}

done_testing;
