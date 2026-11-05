#!/usr/bin/env perl
# desk-trace.pl - drive the Tk desktop through a conversation and report
# the three things that go wrong with it: transcript rebuilds (a rebuild
# destroys and recreates every bubble - a visible flash), the window
# resizing itself, and the screen drifting from what the history renders
# to. bash approvals are always DENIED (nothing the model asks for runs).
#
#   xvfb-run -a -s "-screen 0 1024x768x24" perl util/desk-trace.pl \
#       [--echo examples/desk-echo-script.txt] [--snap out.png] [msg ...]
#
# --echo FILE   use the echo provider with a scripted reply per turn
#               (sections separated by a ---- line), no network
# --snap FILE   capture the window with `import` when done
# msg ...       the messages to send, in order (default: one chat line)
#
# with no --echo it talks to whatever ~/.oldagentrc points at, from an
# empty scratch directory, with approval set to ask.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Tk;
use OldAgent::Config ();
use OldAgent::Desktop ();
use OldAgent::Util ();
use File::Spec ();

my ($echo, $snap);
my @msgs;
while (@ARGV) {
    my $a = shift @ARGV;
    if    ($a eq '--echo') { $echo = File::Spec->rel2abs(shift @ARGV) }   # before the chdir
    elsif ($a eq '--snap') { $snap = File::Spec->rel2abs(shift @ARGV) }
    else                   { push @msgs, $a }
}
@msgs = ('hi, what can you do?') unless @msgs;

# an empty working directory: the model must not find project files
my $dir = OldAgent::Util::tmpdir() . "/oa-desk-trace-$$";
mkdir $dir;
chdir $dir or die "cannot chdir $dir: $!\n";
END { rmdir $dir if defined $dir }

my %ov = (tools => 1, approve => 'ask', thinking => '0');
if (defined $echo) {
    $ov{provider} = 'echo';
    $ENV{OA_ECHO_SCRIPT} = $echo;
}
my $cfg  = OldAgent::Config->load(overrides => \%ov);
my $app  = OldAgent::Desktop->new(config => $cfg);
my $root = $app->{root};
$| = 1;

# --- instrumentation: rebuilds, approvals, events -----------------------
my ($rebuilds, $approvals, $events) = (0, 0, 0);
{
    no warnings 'redefine';
    my $render = \&OldAgent::Desktop::_render_all;
    *OldAgent::Desktop::_render_all = sub { $rebuilds++; $render->(@_) };
    my $event = \&OldAgent::Desktop::_ask_event;
    *OldAgent::Desktop::_ask_event = sub { $events++; $event->(@_) };
    my $dialog = \&OldAgent::Desktop::_approval_dialog;
    *OldAgent::Desktop::_approval_dialog = sub {
        my ($self, $cmd) = @_;
        $approvals++;
        print "approval asked for: $cmd\n";
        $dialog->($self, $cmd);
        $root->after(300, sub {
            my $d = $self->{appr_dlg};
            $self->{appr_dlg} = undef;
            $d->destroy if $d;
            $self->_approval_answer('n');
        });
    };
}
my $base_rebuilds;                   # taken at the first send: the startup
                                     # renders (map, first <Configure>) do not count

# --- the conversation -----------------------------------------------------
my $t0  = time;
my $geo = '';
my @geo_changes;
my $send;
$send = sub {
    my $g = $root->geometry;
    if ($g ne $geo) { push @geo_changes, $g; $geo = $g }
    if ($app->{busy}) { $root->after(200, $send); return }
    if (@msgs) {
        $base_rebuilds = $rebuilds unless defined $base_rebuilds;
        my $m = shift @msgs;
        $app->{entry}->insert(0, $m);
        $app->_send;
        print "sent: $m\n";
        $root->after(200, $send);
        return;
    }
    $root->after(300, \&report);
};
$root->after(400, $send);

sub report {
    my $screen = $app->transcript_text;
    $app->_render_all;                        # what the history renders to
    my $rebuilt = $app->transcript_text;
    (my $s = $screen)  =~ s/^(?:allowed|denied|\(stopped\))\n//mg;   # feed-only notes
    my $same = $s eq $rebuilt;
    print "\n";
    print "history: ", scalar(@{ $app->{agent}->history }), " messages",
          "  events: $events  approvals: $approvals  ", time - $t0, "s\n";
    print "rebuilds during the conversation: ", $rebuilds - $base_rebuilds - 1,
          " (want 0)\n";
    print "window geometry: ", join(' -> ', @geo_changes), (@geo_changes > 1 ? "  (RESIZED)" : "  (steady)"), "\n";
    print "screen == history render: ", ($same ? 'yes' : 'NO'), "\n";
    if (!$same) {
        print "--- screen:\n$screen\n--- history render:\n$rebuilt\n";
    }
    print "status: ", $app->{stat}->cget('-text'), "\n";
    print "send button: ", $app->{btn_send}->cget('-text'), " / ", $app->{btn_send}->cget('-state'), "\n";
    print "--- transcript:\n$screen\n";
    if (defined $snap) {
        $root->update;
        system('import', '-window', $root->id, $snap) == 0
            ? print "snapshot: $snap\n" : print "snapshot failed (import)\n";
    }
    my $bad = ($rebuilds - $base_rebuilds - 1) > 0 || @geo_changes > 1 || !$same
           || $app->{busy};
    $root->destroy;
    exit($bad ? 1 : 0);
}

Tk::MainLoop();
