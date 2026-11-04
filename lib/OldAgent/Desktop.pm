package OldAgent::Desktop;
# A Tk front end on top of the same agent loop the terminal uses.
# Tk is not core perl, so this is loaded lazily and never on the
# critical path: without Tk, everything else in oldagent still runs.

use strict;
use warnings;

use OldAgent ();
use OldAgent::Agent ();
use OldAgent::Textfmt ();

sub new {
    my ($class, %a) = @_;
    my $cfg = $a{config} or die "desktop needs a config\n";

    eval { require Tk; 1 } or do {
        die "Tk is not installed on this perl (try: apt-get install perl-tk / "
          . "cpan Tk). the terminal interface needs no Tk and still works.\n";
    };

    my $self = {
        cfg    => $cfg,
        agent  => OldAgent::Agent->new(config => $cfg),
        root   => Tk::MainWindow->new(-title => "oldagent " . OldAgent::version()),
    };
    bless $self, $class;
    $self->_build();
    return $self;
}

sub _build {
    my ($self) = @_;
    my $rw = $self->{root};

    # the transcript, with markdown tags
    my $txt = $rw->Scrolled('Text',
        -wrap   => 'word',
        -font   => 'Helvetica 11',
        -bg     => '#fdfdfd',
        -fg     => '#111111',
        -height => 18,
        -width  => 78,
        -state  => 'normal',
    )->pack(-side => 'top', -fill => 'both', -expand => 1);

    my %defs = OldAgent::Textfmt::tk_tagdefs();
    for my $name (sort keys %defs) {
        my %defs_o = %{ $defs{$name} };
        my %opt;
        $opt{-font}      = delete $defs_o{font}      if defined $defs_o{font};
        $opt{-foreground} = delete $defs_o{fg}       if defined $defs_o{fg};
        $opt{-background} = delete $defs_o{bg}       if defined $defs_o{bg};
        $opt{-underline}  = delete $defs_o{underline} if defined $defs_o{underline};
        $txt->tag('configure', $name, %opt);
    }

    my $bar = $rw->Frame()->pack(-side => 'bottom', -fill => 'x');
    my $entry = $rw->Entry(-font => 'Helvetica 11')->pack(
        -side => 'left', -fill => 'x', -expand => 1);
    $rw->Button(-text => 'Send',
        -command => sub { $self->_send })->pack(-side => 'right');
    $rw->Button(-text => 'Clear',
        -command => sub {
            $self->{agent}->reset;
            $txt->delete('1.0', 'end');
            $self->_note('conversation cleared');
        })->pack(-side => 'right', -padx => [4, 8]);

    $entry->bind('<Return>', sub { $self->_send });
    $entry->focus;

    $self->{txt}   = $txt;
    $self->{entry} = $entry;
    $self->_note('oldagent ' . OldAgent::version()
        . ' - ' . $self->{cfg}->get('provider') . ' / '
        . $self->{cfg}->get('base_url') . ' / ' . $self->{cfg}->get('model'));
    $self->_note('type and press Enter; this window blocks while the model thinks');
}

sub _note {
    my ($self, $s) = @_;
    my $txt = $self->{txt};
    $txt->insert('end', $s . "\n", 'plain');
    $txt->see('end');
}

sub _render_md {
    my ($self, $text) = @_;
    my $txt = $self->{txt};
    for my $line (OldAgent::Textfmt::tokens($text)) {
        for my $tok (@$line) {
            my ($tags, $str) = @$tok;
            next unless defined $str && length $str;
            $txt->insert('end', $str, @$tags);
        }
        $txt->insert('end', "\n", 'plain');
    }
    $txt->see('end');
}

sub _send {
    my ($self) = @_;
    my $text = $self->{entry}->get();
    return unless length $text;
    $self->{entry}->delete(0, 'end');
    return if $self->{busy};

    $self->_note("\nyou> $text\n");
    $self->{busy} = 1;
    $self->{root}->update;   # paint before the (blocking) model call

    my ($reply, $err) = $self->{agent}->ask($text);
    $self->{busy} = 0;

    if ($err) {
        $self->_render_md("*`oldagent error`: $err*");
    } else {
        $self->_render_md($reply);
    }
    $self->_note("");
}

sub main_loop {
    my ($self) = @_;
    Tk::MainLoop();
    return 0;
}

1;
