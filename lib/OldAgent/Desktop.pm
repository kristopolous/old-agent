package OldAgent::Desktop;
# A Tk front end on top of the same agent loop the terminal uses.
# Tk is not core perl, so this is loaded lazily and never on the
# critical path: without Tk, everything else in oldagent still works.
#
# The window has a menu bar whose items are the REPL's slash commands,
# run through the very same OldAgent::CLI::repl_command handler the
# terminal uses - so the menus can never drift from /help.  Sessions
# (the /save, /load files) get File > New / Save / Open / Recent,
# and a status line shows the current session, provider and model.

use strict;
use warnings;

use OldAgent ();
use OldAgent::Agent ();
use OldAgent::Textfmt ();
use OldAgent::Util ();
use OldAgent::JSON ();
use OldAgent::Protocol ();
eval { require Errno; 1 } or require Errno;
eval { require OldAgent::CLI; 1 } or require OldAgent::CLI;

# utf8 bytes from the wire are inserted into Tk as decoded characters,
# not as latin-1 bytes (the classic "Whatâs up" mojibake).
sub _decode {
    my ($s) = @_;
    return '' unless defined $s;
    return $s if utf8::is_utf8($s);
    my $u = $s;
    my $ok = eval { no warnings 'utf8'; utf8::decode($u); 1 };
    return $ok ? $u : $s;
}

# the look of the transcript: a white page, the human in blue, the
# agent in plain text, and the one font everything shares
my $PAGE_BG = '#ffffff';
my $USER_FG = '#0b5cc4';
my $FONT    = 'Helvetica 11';

# ------------------------------------------------------------------ output

# A tied handle: while it is the selected filehandle, every plain `print`
# in the oldagent code lands in the owner's capture buffer instead of the
# terminal. _run_cmd turns the buffer into feed items afterwards.
package OldAgent::Desktop::_Out;
sub TIEHANDLE {
    my ($class, $owner) = @_;
    return bless { owner => $owner }, $class;
}
sub _put {
    my ($s, $str) = @_;
    return unless defined $str && length $str;
    $s->{owner}{capbuf} .= $str;
}
# print HANDLE 'a', 'b'      -> PRINT, one call per argument (list)
sub PRINT { my ($s, @rest) = @_; $s->_put($_) for @rest; return 1 }
# print HANDLE $scalar       -> WRITE, one call with the scalar
sub WRITE { my ($s, $str) = @_; $s->_put($str); return 1 }
# printf HANDLE fmt, ...     -> PRINTF (/config and /history use it)
sub PRINTF { my ($s, $fmt, @rest) = @_; $s->_put(sprintf($fmt, @rest)); return 1 }
sub CLOSE { return 1 }

# ---------------------------------------------------------------- sessions

package OldAgent::Desktop;

sub session_dir {
    my $home = $ENV{HOME} ? $ENV{HOME}
              : ($ENV{USERPROFILE} ? $ENV{USERPROFILE} : '.');
    my $dir = $home . '/.oldagent/sessions';
    _mkdir_p($dir);
    return $dir;
}

# mkdir -p, without File::Path (not in every old perl)
sub _mkdir_p {
    my ($path) = @_;
    return 1 if -d $path;
    my $parent = ($path =~ m{^(.*)/[^/]+$}) ? $1 : '';
    _mkdir_p($parent) if length $parent && $parent ne '/' && !-d $parent;
    return mkdir($path) || -d $path;
}

sub _registry_path { OldAgent::Desktop::session_dir() . '/.index.json' }

sub _read_json {
    my ($path) = @_;
    open(my $fh, '<', $path) or return undef;
    my $s = do { local $/; <$fh> };
    close($fh);
    my ($d, $err) = eval { OldAgent::JSON::decode($s) };
    return $@ ? undef : ($err ? undef : $d);
}

sub _write_json {
    my ($path, $data) = @_;
    my $tmp = $path . '.tmp' . $$;
    OldAgent::Util::spew($tmp, OldAgent::JSON::encode($data));
    rename($tmp, $path) or die "cannot write $path: $!\n";
}

sub load_registry {
    my $r = OldAgent::Desktop::_read_json(OldAgent::Desktop::_registry_path());
    return ref($r) eq 'ARRAY' ? $r : [];
}

sub remember_session {
    my ($name, $path, $turns) = @_;
    my @reg = @{ OldAgent::Desktop::load_registry() };
    @reg = grep { $_->{path} ne $path } @reg;
    unshift @reg, { name => $name, path => $path, mtime => time(), turns => $turns };
    @reg = @reg[0 .. 9] if @reg > 10;
    OldAgent::Desktop::_write_json(OldAgent::Desktop::_registry_path(), \@reg);
}

# --------------------------------------------------------------------- app

sub new {
    my ($class, %a) = @_;
    my $cfg = $a{config} or die "desktop needs a config\n";

    eval { require Tk; 1 } or do {
        die "Tk is not installed on this perl (try: apt-get install perl-tk / "
          . "cpan Tk). the terminal interface needs no Tk and still works.\n";
    };

    my $self = {
        cfg     => $cfg,
        agent   => OldAgent::Agent->new(config => $cfg),
        root    => Tk::MainWindow->new(-title => "oldagent " . OldAgent::version()),
        session => 'untitled',
        busy    => 0,
    };
    bless $self, $class;
    $self->_build();
    $self->_redraw();
    return $self;
}

sub _build {
    my ($self) = @_;
    my $rw = $self->{root};

    # ---- menu bar: File / Commands / Help -----------------------------
    # this Tk build's ->Cascade returns a stub with no ->add, and
    # Menu(-label) is rejected. the recipe that works (verified under
    # xvfb): a plain menubar, the three top-level submenus declared back
    # to back, then each menu filled depth-first - a menu's nested
    # submenu is created as soon as its plain items are done, before
    # touching the next top-level menu. interleaving loses entries.
    # (also: in this build index('end') is one less than the real count)
    my $menubar = $rw->Menu();
    my $file    = _bar($menubar, 'File');
    my $cmds    = _bar($menubar, 'Commands');
    my $help    = _bar($menubar, 'Help');
    $self->{menubar}   = $menubar;
    $self->{file_menu} = $file;
    $self->{cmds_menu} = $cmds;
    $self->{help_menu} = $help;
    $rw->configure(-menu => $menubar);

    # File - plain items only (the Recent submenu is created at the end)
    $self->_item($file, 'New session',     sub { $self->new_session() });
    $self->_item($file, 'Save session...', sub { $self->save_session() });
    $self->_item($file, 'Open session...', sub { $self->open_session() });
    $file->Separator();
    $self->_item($file, 'Quit', sub { $rw->destroy });

    # File's nested submenu, while File is still the active menu
    $self->{recent} = _bar($file, 'Recent');
    $self->_rebuild_recent();

    # Commands - one item per slash command, same handler as the REPL
    $self->_item($cmds, 'Help',                 sub { $self->_show_help() });
    $self->_item($cmds, 'History',              sub { $self->_run_cmd('history') });
    $self->_item($cmds, 'Undo last exchange',   sub { $self->_run_cmd('undo');  $self->_redraw() });
    $self->_item($cmds, 'Clear conversation',   sub { $self->_run_cmd('clear'); $self->_redraw() });
    $cmds->Separator();
    $self->_item($cmds, 'Model...',             sub { $self->_arg_cmd('model', 'Set model', $self->{cfg}->get('model')) });
    $self->_item($cmds, 'Provider or URL...',   sub { $self->_arg_cmd('provider', 'Set provider (name or url)', $self->{cfg}->get('provider')) });
    $self->_item($cmds, 'Base URL...',          sub { $self->_arg_cmd('base-url', 'Set base url', $self->{cfg}->get('base_url') || '') });
    $self->_item($cmds, 'Max turns...',         sub { $self->_arg_cmd('turns', 'Max tool round trips per message', $self->{cfg}->get('max_turns')) });
    $self->_item($cmds, 'Extra instructions...', sub { $self->_arg_cmd('system', 'Standing instructions for the model', '') });
    $self->_item($cmds, 'Working directory...', sub { $self->_arg_cmd('cd', 'Change working directory to', OldAgent::Util::cwd()) });
    $self->_item($cmds, 'Shell command...',     sub { $self->_arg_cmd('sh', 'Run a shell command now (outside the conversation)', '') });
    $cmds->Separator();
    $self->_item($cmds, 'Doctor (environment report)', sub { $self->_run_cmd('doctor') });
    $self->_item($cmds, 'Show config',                sub { $self->_run_cmd('config') });
    $self->_item($cmds, 'Version',                    sub { $self->_run_cmd('version') });
    $cmds->Separator();
    $self->_item($cmds, 'Save session...',           sub { $self->save_session() });
    $self->_item($cmds, 'Open session...',           sub { $self->open_session() });

    # Commands' nested submenus, while Commands is still the active menu
    my $tools = _bar($cmds, 'Tools');
    $self->{tools_menu} = $tools;
    $self->{tools_var} = $self->{cfg}->get('tools') ? 'on' : 'off';
    $tools->add('radiobutton', -label => 'On',
        -variable => \$self->{tools_var}, -value => 'on',
        -command  => sub { $self->_set_tools('on') });
    $tools->add('radiobutton', -label => 'Off',
        -variable => \$self->{tools_var}, -value => 'off',
        -command  => sub { $self->_set_tools('off') });

    my $appr = _bar($cmds, 'Bash approval');
    $self->{appr_menu} = $appr;
    $self->{appr_var} = ($self->{cfg}->get('approve') eq 'auto') ? 'auto' : 'ask';
    $appr->add('radiobutton', -label => 'Ask first',
        -variable => \$self->{appr_var}, -value => 'ask',
        -command  => sub { $self->_set_approve('ask') });
    $appr->add('radiobutton', -label => 'Run without asking',
        -variable => \$self->{appr_var}, -value => 'auto',
        -command  => sub { $self->_set_approve('auto') });

    # Help
    $self->_item($help, 'REPL reference', sub {
        $self->_show_text('oldagent REPL reference', OldAgent::CLI::_repl_help());
    });
    $self->_item($help, 'About oldagent', sub {
        $self->_show_text('About oldagent',
            "oldagent " . OldAgent::version() . "\n\n"
            . "a pure-perl agent that runs on a perl from around 2000.\n"
            . "this window and the terminal share one agent loop;\n"
            . "the menus below are the /commands, run by the same code.\n"
            . "sessions are plain files: " . OldAgent::Desktop::session_dir() . "\n");
    });

    # ---- transcript -----------------------------------------------------
    # Scrolled() would pack an x-scrollbar in as well, but the text wraps
    # (word), so it can never scroll horizontally - build the y-scrollbar
    # by hand and let the text claim everything else.
    my $vsb = $rw->Scrollbar(-bg => '#eeeeee')->pack(-side => 'right', -fill => 'y');
    my $txt = $rw->Text(
        -wrap   => 'word',
        -font   => $FONT,
        -bg     => $PAGE_BG,
        -fg     => '#111111',
        -height => 20,
        -width  => 40,
        -state  => 'normal',
        -yscrollcommand => [$vsb, 'set'],
    )->pack(-side => 'top', -fill => 'both', -expand => 1);
    $vsb->configure(-command => [$txt, 'yview']);

    # the markdown tags, straight on the transcript
    my %defs = OldAgent::Textfmt::tk_tagdefs();
    for my $name (sort keys %defs) {
        my %o = %{ $defs{$name} };
        my %opt;
        $opt{-font}       = $o{font}      if defined $o{font};
        $opt{-foreground} = $o{fg}        if defined $o{fg};
        $opt{-background} = $o{bg}        if defined $o{bg};
        $opt{-underline}  = $o{underline} if defined $o{underline};
        $txt->tag('configure', $name, %opt) if %opt;
    }
    # the human: blue, right-aligned. a thin blank line around a message
    # (a tiny font, so the gap is a few pixels, not a whole text line)
    $txt->tag('configure', 'user',    -foreground => $USER_FG, -justify => 'right');
    $txt->tag('configure', 'gap',     -font => 'Helvetica 3');
    $txt->tag('configure', 'tool',    -font => 'Helvetica 10', -foreground => '#777777',
        -lmargin1 => 8, -lmargin2 => 48);
    $txt->tag('configure', 'toolout', -font => 'Courier 10', -foreground => '#555555',
        -lmargin1 => 24, -lmargin2 => 24);
    $txt->tag('configure', 'sys',     -foreground => '#666666');
    $txt->tag('configure', 'note',    -foreground => '#555555', -font => 'Helvetica 10 italic');
    $txt->tag('configure', 'err',     -foreground => '#b00020');
    $self->{txt} = $txt;

    # a resize changes the bubble width: re-render the whole transcript
    # (it is plain text, so this is cheap) and every user bubble re-pads
    # itself for the new width. throttle: one re-render 120ms after the
    # last configure event of a drag.
    # (afterCancel via the widget's method table - this Tk build has no
    # package-level Tk::afterCancel)
    my $pend;
    $txt->bind('<Configure>', sub {
        my ($w) = @_;
        my $wd = $w->winfo('width');
        return if $wd == $self->{last_width} || $self->{rendering};
        $self->{last_width} = $wd;
        $w->afterCancel($pend) if defined $pend;
        $pend = $rw->after(120, sub { $pend = undef; $self->_render_all() });
    });
    $self->{feed}      = [];
    $self->{capbuf}    = '';
    $self->{rendering} = 0;
    $self->{last_width} = 0;

    # ---- input row + status line --------------------------------------
    # this Tk build's pack is broken for widgets inside an intermediate
    # frame (the frame collapses to 1px and its children stop stretching),
    # so everything here is a direct child of the root window, packed in
    # this order: status takes the bottom row, the buttons claim the right
    # of the row above it, and the entry fills the rest of that row.
    # -width 1: the label asks for (almost) no width of its own and is
    # stretched by -fill x. a label that asks for the width of its text
    # grows the whole window when the text is long ("THINKING..." at the
    # end of a busy status line) and shrinks it back when it is short:
    # that was the "resize window" between every message and its reply.
    my $stat = $rw->Label(-anchor => 'w', -width => 1,
        -bg => '#eeeeee', -fg => '#555555', -font => 'Helvetica 10', -padx => 8)
        ->pack(-side => 'bottom', -fill => 'x');
    # only Send sits beside the entry: Undo and Clear are conversation
    # commands, not input actions - they live in the Commands menu, next
    # to the other /commands.
    $self->{btn_send} = $rw->Button(-text => 'Send', -default => 'active',
        -command => sub { $self->_send })
        ->pack(-side => 'right', -padx => [2, 10], -pady => 6);
    # Stop kills the agent child mid-turn; live only while one is running
    $self->{btn_stop} = $rw->Button(-text => 'Stop', -state => 'disabled',
        -command => sub { $self->_stop })
        ->pack(-side => 'right', -padx => 2, -pady => 6);
    my $entry = $rw->Entry(-font => 'Helvetica 12', -relief => 'sunken', -bg => '#fffef5')
        ->pack(-side => 'bottom', -fill => 'x', -padx => [8, 4], -pady => 6);
    # in this Tk build the entry's natural height is a few px shorter than
    # the button's, and Entry does not accept -height at all - so measure
    # the gap after the first layout and close it with internal padding,
    # which does change the widget's real height.
    $rw->update;
    my $dh = $self->{btn_send}->winfo('height') - $entry->winfo('height');
    $entry->packConfigure(-ipady => int($dh / 2)) if $dh > 0;
    # pin the size: from here on only the human (or the window manager)
    # resizes this window, never a child widget's request
    $rw->update;
    $rw->geometry($rw->winfo('width') . 'x' . $rw->winfo('height'));
    $entry->bind('<Return>', sub { $self->_send });
    $entry->focus;
    $self->{entry} = $entry;

    $self->{stat} = $stat;
    $self->_status();
}

# -------------------------------------------------------------- menu items

# add a command item to a menu
sub _item {
    my ($self, $menu, $label, $cb) = @_;
    return $menu->add('command', -label => $label, -command => $cb);
}

# build a labelled submenu bar (works around this Tk build's stub Cascade)
sub _bar {
    my ($parent, $label) = @_;
    my $m = $parent->Menu(-tearoff => 0);
    $parent->add('cascade', -label => $label, -menu => $m);
    return $m;
}

sub _set_tools {
    my ($self, $v) = @_;
    $self->{cfg}->set(tools => $v eq 'on' ? 1 : 0);
    $self->{agent}{tools_on} = $v eq 'on' ? 1 : 0;
    my $p = $self->{cfg}->remember('tools');
    $self->_status();
    $self->_flash("tools $v" . ($p ? "  (remembered in $p)" : ''));
}

sub _set_approve {
    my ($self, $v) = @_;
    $self->{cfg}->set(approve => $v);
    my $p = $self->{cfg}->remember('approve');
    my $s = $v eq 'auto' ? 'bash runs without asking' : 'bash asks first';
    $self->_flash($s . ($p ? "  (remembered in $p)" : ''));
}

sub _rebuild_recent {
    my ($self) = @_;
    my $m = $self->{recent} or return;
    $m->delete(0, 'end');
    my @reg = @{ OldAgent::Desktop::load_registry() };
    unless (@reg) {
        $m->add('command', -label => '(no sessions yet)', -state => 'disabled');
    }
    for my $e (@reg) {
        my $e = $e;
        $m->add('command',
            -label => $e->{name} . '  (' . ($e->{turns} || 0) . ' turns)',
            -command => sub { $self->_load_path($e->{path}) });
    }
    $m->add('command', -label => 'Refresh',
        -command => sub { $self->_rebuild_recent() });
}

# ------------------------------------------------- commands via the REPL --

# run one of the /commands through the same handler the terminal uses,
# capturing its output as feed items (rendered as quiet sys lines).
sub _run_cmd {
    my ($self, $c, $rest) = @_;
    $rest = defined $rest ? $rest : '';
    $self->{capbuf} = '';
    unless (tie(*OA_CAP_1, 'OldAgent::Desktop::_Out', $self)) {
        $self->_flash('cannot capture output');
        return;
    }
    my $prev = select(OA_CAP_1);
    my $r = eval { OldAgent::CLI::repl_command($c, $rest,
        agent => $self->{agent}, config => $self->{cfg}, term => undef) };
    select($prev);
    for my $line (split(/\n/, $self->{capbuf} || '')) {
        next unless length $line;
        push @{ $self->{feed} }, ['sys', $line];
    }
    $self->{capbuf} = '';
    push @{ $self->{feed} }, ['err', "error: $@"] if $@;
    $self->_render_all();
    $self->_status();
    return $r;
}

# a command that asks for an argument first
# slash command -> config keys to persist after it changes them
my %PERSIST_KEYS = (
    model      => [qw(model)],
    provider   => [qw(provider base_url api_key key_env)],
    'base-url' => [qw(base_url)],
    turns      => [qw(max_turns)],
    system     => [qw(system_extra)],
);

# real prompts for the one-field dialogs; the menu items pass a window
# title, this is what the label inside the dialog says.
my %ARG_PROMPT = (
    model     => 'model name (e.g. gpt-4o-mini)',
    provider  => 'provider name or endpoint URL (openai, ollama, https://host/v1)',
    'base-url'=> 'endpoint URL (e.g. http://localhost:11434/v1)',
    turns     => 'max tool round trips per message (number)',
    system    => 'standing instructions for the model',
    cd        => 'new working directory',
    sh        => 'shell command to run now, outside the conversation',
);

sub _arg_cmd {
    my ($self, $c, $title, $default) = @_;
    $self->_ask(title => $title, prompt => $ARG_PROMPT{$c} || $title,
        default => $default,
        done => sub {
            my ($a) = @_;
            $self->_run_cmd($c, $a);
            my $keys = $PERSIST_KEYS{$c};
            if ($keys) {
                my $p = $self->{cfg}->remember(@$keys);
                $self->_flash("remembered in $p") if $p;
            }
            $self->_status();
        });
}

# --------------------------------------------------------------- sessions --

sub new_session {
    my ($self) = @_;
    $self->{agent}->reset;
    $self->{session} = 'untitled';
    $self->_redraw();
    $self->_flash('new session');
    $self->{entry}->focus;
}

sub save_session {
    my ($self) = @_;
    $self->_ask(title => 'Save session',
        prompt  => 'session name (stored in ' . OldAgent::Desktop::session_dir() . ')',
        default => $self->{session} eq 'untitled' ? 'session' : $self->{session},
        done => sub {
            my ($name) = @_;
            return unless length $name;
            $name =~ s{[^A-Za-z0-9_.-]+}{_}g;
            my $path = OldAgent::Desktop::session_dir() . '/' . $name . '.json';
            $self->_run_cmd('save', $path);
            my $n = scalar(@{ $self->{agent}->history() });
            OldAgent::Desktop::remember_session($name, $path, scalar(grep { $_->{role} eq 'user' } @{ $self->{agent}->history() }));
            $self->{session} = $name;
            $self->_rebuild_recent();
            $self->_status();
            $self->_flash('saved ' . $n . ' messages as ' . $path);
        });
}

sub open_session {
    my ($self) = @_;
    my $f = Tk::getOpenFile(-title => 'Open session',
        -filetypes => [['json sessions', '.json'], ['all files', '*']],
        -initialdir => OldAgent::Desktop::session_dir());
    $self->_load_path($f) if $f;
    return;
}

sub _load_path {
    my ($self, $path) = @_;
    return unless $path && length $path;
    $self->_run_cmd('load', $path);
    my ($name) = $path =~ m{([^/\\]+)\.json$};
    $self->{session} = $name || 'session';
    $self->_redraw();
    $self->_status();
    $self->_flash('loaded ' . $path);
}

# ------------------------------------------------------------------ dialog --

# a one-field dialog. NON-BLOCKING: returns immediately; when the user
# clicks OK (or presses Return), $o{done} is called with the text,
# scheduled one main-loop tick after the window is destroyed. Cancel and
# the window close never call it.
#
# Why no wait: in this Tk build waitWindow and waitVariable never wake up
# (verified: the main loop stays parked forever), and pumping update()
# inline from a menu callback re-enters the event loop and crashes
# ("Modification of a read-only value attempted"). A dialog that parks
# the main loop is a dialog that locks the app - so the app stays in the
# main loop, and the answer rides back through it.
sub _ask {
    my ($self, %o) = @_;
    my $rw   = $self->{root};
    my $done = $o{done} or return;
    my $t = eval { $rw->Toplevel(-title => $o{title} || 'oldagent') };
    if (!$t) { $self->_flash("dialog failed: $@"); return }

    # direct children of the toplevel - same frame-pack quirk as the
    # input row: an intermediate frame would collapse to 1px here too.
    my $lab = $t->Label(-text => $o{prompt} || '', -justify => 'left')
        ->pack(-anchor => 'w', -padx => [12, 4], -pady => [12, 6]);
    my $e = $t->Entry(-width => 44, -relief => 'sunken')
        ->pack(-fill => 'x', -expand => 1, -padx => 12, -pady => 4);
    $e->insert(0, $o{default} || '');
    my $finish = sub {
        my $v = $e->get;
        $v = '' unless defined $v;
        $t->destroy;
        $rw->after(10, sub { $done->($v) });
    };
    $t->Button(-text => 'OK', -command => $finish)
        ->pack(-side => 'right', -padx => [4, 12], -pady => 10);
    $t->Button(-text => 'Cancel', -command => sub { $t->destroy })
        ->pack(-side => 'right', -padx => 4, -pady => 10);
    $e->bind('<Return>', $finish);
    $t->bind('<Return>', $finish);
    $e->focus;
}

# the model wants to run a bash command: Allow / Always / Deny. the child
# is parked on its stdin until one line comes back, so the answer is
# written there (y / a / n); Always also flips the setting for the rest
# of the session.
sub _approval_dialog {
    my ($self, $cmd) = @_;
    my $rw = $self->{root};
    my $t = eval { $rw->Toplevel(-title => 'oldagent: allow this command?') };
    if (!$t) { $self->_approval_answer('n'); return }
    $self->{appr_dlg} = $t;
    $t->Label(-text => 'the model wants to run this command:', -justify => 'left')
        ->pack(-anchor => 'w', -padx => 12, -pady => [12, 4]);
    my @lines = split(/\n/, $cmd);
    my $h = @lines < 2 ? 2 : (@lines > 10 ? 10 : scalar @lines);
    my $box = $t->Text(-height => $h, -width => 72, -font => 'Courier 10',
        -wrap => 'word', -bg => '#f8f8f0', -relief => 'sunken')
        ->pack(-fill => 'both', -expand => 1, -padx => 12, -pady => 4);
    $box->insert('1.0', $cmd);
    $box->configure(-state => 'disabled');
    my $answer = sub {
        my ($a) = @_;
        $self->{appr_dlg} = undef;
        $t->destroy;
        $rw->after(10, sub { $self->_approval_answer($a) });
    };
    $t->Button(-text => 'Deny',   -command => sub { $answer->('n') })
        ->pack(-side => 'right', -padx => [4, 12], -pady => 10);
    $t->Button(-text => 'Always', -command => sub { $answer->('a') })
        ->pack(-side => 'right', -padx => 4, -pady => 10);
    $t->Button(-text => 'Allow',  -command => sub { $answer->('y') })
        ->pack(-side => 'right', -padx => 4, -pady => 10);
    $t->bind('<Return>', sub { $answer->('y') });
    $t->bind('<Escape>', sub { $answer->('n') });
    $t->protocol('WM_DELETE_WINDOW', sub { $answer->('n') });
}

sub _approval_answer {
    my ($self, $a) = @_;
    my $fh = $self->{ask_wr} or return;
    print $fh "$a\n";
    if ($a eq 'a') {
        $self->{appr_var} = 'auto';
        $self->_set_approve('auto');
    }
    $self->_append_item(['note', $a eq 'n' ? 'denied' : 'allowed']);
}

# a read-only text window
sub _show_text {
    my ($self, $title, $body) = @_;
    my $t = $self->{root}->Toplevel(-title => $title);
    my $tx = $t->Scrolled('Text', -wrap => 'none', -font => 'Courier 10',
        -width => 74, -height => 26, -state => 'disabled')
        ->pack(-fill => 'both', -expand => 1);
    $tx->configure(-state => 'normal');
    $tx->insert('1.0', $body);
    $tx->configure(-state => 'disabled');
    $tx->tag('configure', 'sel', -background => '#c8e0ff');
    $t->Button(-text => 'Close',
        -command => sub { $t->destroy })
        ->pack(-side => 'bottom', -fill => 'x', -pady => 6);
}

sub _show_help {
    my ($self) = @_;
    $self->_show_text('oldagent REPL reference', OldAgent::CLI::_repl_help());
}

# ------------------------------------------------------------------- I/O --

sub _send {
    my ($self) = @_;
    my $text = $self->{entry}->get();
    return unless length $text;
    $self->{entry}->delete(0, 'end');
    return if $self->{busy};

    # the first message replaces the welcome text
    $self->{txt}->delete('1.0', 'end')
        if !@{ $self->{agent}->history() } && !@{ $self->{feed} };
    $self->_append_item(['user', $text]);

    # The model call runs in a SEPARATE PROCESS. This Tk build's main loop
    # is the only thing that can process events; a blocking ask() in it is
    # a frozen window (dead buttons, no repaint). So we fork+exec a fresh
    # perl that rebuilds the agent from the same settings and transcript,
    # answers, and pipes one JSON line back. The parent keeps pumping
    # events the whole time. The message goes down the child's stdin,
    # the events come back up its stdout, one JSON line each.
    my ($rd, $wr, $ird, $iwr);
    (pipe($rd, $wr) && pipe($ird, $iwr)) or do {
        my $e = $!;
        push @{ $self->{feed} }, ['err', "error: cannot spawn agent: $e"];
        $self->_render_all();
        return;
    };

    my $selfpath = __FILE__;
    if ($selfpath !~ m{^/}) {
        my $cwd = (eval { require POSIX; POSIX::getcwd() }) || '';
        $selfpath = $cwd . '/' . $selfpath if $cwd;
    }
    my ($libdir) = $selfpath =~ m{^(.*)[/\\]OldAgent[/\\]Desktop\.pm$}s or do {
        close $rd; close $wr;
        $self->{txt}->insert('end', "error: cannot locate lib dir\n", 'err');
        return;
    };
    my $child = $libdir . '/OldAgent/desktop-child.pl';

    # send the whole current config, not a hand-picked subset: the child
    # rebuilds the agent from this, so a key left out here (api_key,
    # max_tokens, thinking, timeout, ...) silently falls back to its default
    # and the request goes out wrong - e.g. unauthenticated to a proxy.
    # (one line of JSON: it travels down a pipe, line by line)
    my $msg = OldAgent::JSON::encode({
        text       => $text,
        cfg        => $self->{agent}{cfg}->all(),
        max_output => $self->{agent}{cfg}->get('max_output') || 3000,
        history    => [ map { { role => $_->{role}, content => $_->{content} } }
                        @{ $self->{agent}{history} } ],
    });

    my $kid = fork();
    if (!defined $kid) {
        my $e = $!;
        close $rd; close $wr;
        push @{ $self->{feed} }, ['err', "error: cannot fork: $e"];
        $self->_render_all();
        return;
    }
    if ($kid == 0) {
        # child: its stdout becomes the event pipe and its stdin the answer
        # pipe (approval replies); drop the other ends; exec a clean perl
        # (no Tk, no X).
        open(STDOUT, '>&=', $wr)  or exit 9;
        open(STDIN,  '<&=', $ird) or exit 9;
        close $rd; close $wr; close $ird; close $iwr;
        exec('perl', $child, $libdir) or exit 9;
        exit 9;
    }
    close $wr;
    close $ird;
    { my $prev = select($iwr); $| = 1; select($prev) }
    $self->{ask_wr} = $iwr;
    # the message goes down the child's stdin as its first line (argv
    # would show the api key to every user on the box); the child reads
    # it as soon as it starts, so a long transcript cannot wedge us here
    print $iwr $msg, "\n";
    # non-blocking read end: sysread must never hold up the Tk event loop.
    # (fcntl is a perl builtin; a Fcntl::fcntl() call inside an eval used
    # to fail silently here, so the read blocked the whole window until
    # the child wrote something - and a child waiting for an approval
    # answer never does: a deadlock.)
    if (eval { require Fcntl; 1 }) {
        my $fl = fcntl($rd, Fcntl::F_GETFL(), 0);
        if (defined $fl) {
            fcntl($rd, Fcntl::F_SETFL(), $fl | Fcntl::O_NONBLOCK())
                or push @{ $self->{feed} }, ['err', "warning: cannot make the agent pipe non-blocking: $!"];
        }
    }
    $self->{busy}     = 1;
    $self->{btn_send}->configure(-state => 'disabled', -text => 'Thinking');
    $self->{btn_stop}->configure(-state => 'normal');
    $self->{acc}      = '';
    $self->{ask_rd}   = $rd;
    $self->{ask_kid}  = $kid;
    $self->{ask_text} = $text;
    $self->{ask_final_seen} = 0;
    $self->_status('busy');
    $self->{root}->after(50, sub { $self->_ask_poll() });
}

sub _ask_poll {
    my ($self) = @_;
    my $rd = $self->{ask_rd};
    return unless defined $rd;
    my $n = sysread($rd, my $chunk, 65536);
    if (!defined $n) {
        if ($!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR}) {  # no data yet
            $self->{root}->after(50, sub { $self->_ask_poll() });
            return;
        }
        close $rd;
        $self->{ask_rd} = undef;
        $self->_ask_final({ ok => 0, err => 'agent connection lost',
            reply => '', history => [ map { { role => $_->{role}, content => $_->{content} } } @{ $self->{agent}{history} } ] });
        return;
    }
    if ($n == 0) {                            # pipe closed
        close $rd;
        $self->{ask_rd} = undef;
        if (length $self->{acc}) {
            $self->_ask_event($self->{acc});
            $self->{acc} = '';
        }
        $self->_ask_final({ ok => 0, err => 'agent died before finishing',
            reply => '', history => [ map { { role => $_->{role}, content => $_->{content} } } @{ $self->{agent}{history} } ] })
            if !$self->{ask_final_seen};
        return;
    }
    $self->{acc} .= $chunk;
    while ($self->{acc} =~ s/^(.*?\n)//s) {
        $self->_ask_event($1);
    }
    $self->{root}->after(50, sub { $self->_ask_poll() })
        if defined $self->{ask_rd} && !$self->{ask_final_seen};
    return;
}

# one JSON line from the agent child: note / delta / round / final.
# everything lands in the feed and the transcript is re-rendered as a
# whole; the live bubble is just a feed item, so a resize mid-stream
# re-pads everything and the stream continues seamlessly.
sub _ask_event {
    my ($self, $line) = @_;
    $line =~ s/\r?\n\z//;
    return unless length $line;
    my ($ev, $err) = eval { OldAgent::JSON::decode($line) };
    if (!$ev || ref($ev) ne 'HASH') {
        # child printed something that is not protocol: show it, keep going
        push @{ $self->{feed} }, ['err', $line];
        $self->_render_all();
        return;
    }
    my $type = $ev->{type} || 'final';        # no type: one-shot legacy line
    # every event is drawn where it lands: appended, or grown in place.
    # the transcript is never rebuilt for an event - a rebuild destroys
    # and recreates every bubble widget, and that is a visible flash.
    if ($type eq 'note') {
        my $t = _decode(defined $ev->{text} ? $ev->{text} : '');
        return unless length $t;
        # the terminal's "[tool] name args..." progress lines: the round
        # event renders the call in full a moment later, so these would
        # only double it (with the terminal's ellipsis, too)
        return if $t =~ /^\[tool\] /;
        $self->_append_item(['note', $t]);
    }
    elsif ($type eq 'delta') {
        my $t = defined $ev->{text} ? $ev->{text} : '';
        return unless length $t;
        $self->_live_append($t);
    }
    elsif ($type eq 'umsg') {
        # a user-role message the agent pushed itself (a tool result
        # block, a nudge): drawn exactly as the history will draw it
        my $t = defined $ev->{text} ? $ev->{text} : '';
        $self->_append_item(['umsg', $t]) if length $t;
    }
    elsif ($type eq 'ask') {
        # the child wants a bash command approved; it is blocked on its
        # stdin until the human answers through the window
        my $cmd = _decode(defined $ev->{cmd} ? $ev->{cmd} : '');
        $self->_approval_dialog($cmd);
    }
    elsif ($type eq 'round') {
        # the streamed bubble (if any) is raw tokens: take it off the end
        # and draw the finished reply (markdown bubble + tool lines) in
        # its place. nothing above it is touched.
        my $t = _decode(defined $ev->{text} ? $ev->{text} : '');
        $self->_replace_live($t);
    }
    elsif ($type eq 'final') {
        $self->_ask_final($ev);
    }
}

sub _ask_final {
    my ($self, $msg) = @_;
    return if $self->{ask_final_seen};
    $self->{ask_final_seen} = 1;
    if (defined $self->{ask_rd}) { close $self->{ask_rd}; $self->{ask_rd} = undef }
    if (defined $self->{ask_wr}) { close $self->{ask_wr}; $self->{ask_wr} = undef }
    if ($self->{appr_dlg}) { eval { $self->{appr_dlg}->destroy }; $self->{appr_dlg} = undef }
    if (defined $self->{ask_kid}) {
        my $w = 1;
        while ($w && ($w = waitpid($self->{ask_kid}, 1)) > 0) {}   # reap
        $self->{ask_kid} = undef;
    }
    $self->{busy} = 0;
    $self->{btn_send}->configure(-state => 'normal', -text => 'Send');
    $self->{btn_stop}->configure(-state => 'disabled');

    # fold the child's conversation back in (it ran with our history).
    # what is on screen was drawn from the events as they came, and the
    # history renders to exactly the same thing - so NO redraw here: that
    # rebuild was the flash at the end of every turn.
    my $redraw = 0;
    if (ref($msg->{history}) && @{$msg->{history}}) {
        $self->{agent}{history} = [ map { { role => $_->{role}, content => $_->{content} } } @{ $msg->{history} } ];
        $self->{feed} = [];
    }

    if (!$msg->{ok}) {
        # only surface the error if no assistant reply made it on screen
        my $rendered = grep { $_->{role} eq 'assistant' } @{ $self->{agent}{history} };
        unless ($rendered) {
            push @{ $self->{feed} },
                ['err', _decode(defined $msg->{err} ? $msg->{err} : 'unknown')];
            $redraw = 1;
        }
    }
    $self->_render_all() if $redraw;
    $self->_status();
}

# the human pressed Stop: kill the child and keep what is on screen. the
# message and whatever streamed back so far go into the history as they
# stand, so the transcript stays honest and the next message continues
# from here.
sub _stop {
    my ($self) = @_;
    return unless $self->{busy};
    kill('TERM', $self->{ask_kid}) if defined $self->{ask_kid};
    my @h = map { { role => $_->{role}, content => $_->{content} } }
            @{ $self->{agent}{history} };
    push @h, { role => 'user', content => $self->{ask_text} }
        if defined $self->{ask_text} && length $self->{ask_text};
    my $live = '';
    for my $it (@{ $self->{feed} }) {
        $live = $it->[1] if $it->[0] eq 'live' || $it->[0] eq 'assistant';
    }
    push @h, { role => 'assistant', content => $live } if length $live;
    $self->_ask_final({ ok => 1, history => \@h });
    push @{ $self->{feed} }, ['note', '(stopped)'];
    $self->_render_all();
}

# ---------------------------------------------------------------- render --
# the transcript is a pure function of (history, feed). feed holds what
# has not been folded into the history yet: /command output, notes, the
# in-flight user message, the live streamed reply.
#
# it is ONE text widget and nothing but tags: the human's lines are blue
# and right-aligned, the agent's are plain with the markdown tags, tool
# lines are small and grey. no boxes, no backgrounds, no widgets per
# message, nothing measured - Tk wraps the text itself. that is what
# keeps it quick on a machine from the last century.

sub _render_all {
    my ($self) = @_;
    return if $self->{rendering};
    $self->{rendering} = 1;
    my $txt = $self->{txt};
    $self->{last_width} = $txt->winfo('width');
    $txt->delete('1.0', 'end');
    $self->{live} = 0;

    my @h = @{ $self->{agent}->history() };
    if (!@h && !@{ $self->{feed} }) {
        my $prov  = $self->{cfg}->get('provider');
        my $model = $self->{cfg}->get('model');
        my $base  = $self->{cfg}->get('base_url');
        $txt->insert('end', "\n", 'plain');
        $txt->insert('end',
            "start: type a message below and press Enter\n", 'note');
        $txt->insert('end',
            "commands: the menu bar above is the /commands - pick from"
            . " Commands (Model, Provider, Base URL, Tools, Approve...), "
            . "or type /help below for the full list.\n", 'note');
        $txt->insert('end',
            "ready: $prov / $model" . ($base ? " at $base" : '') . "\n", 'note');
    }
    for my $m (@h) {
        $self->_render_msg($m->{role}, $m->{content}) if defined $m->{content};
    }
    for my $it (@{ $self->{feed} }) {
        $self->_render_item($it);
    }
    $txt->see('end');
    $self->{rendering} = 0;
}

# add one item to the feed and draw it at the end of the transcript
sub _append_item {
    my ($self, $it) = @_;
    push @{ $self->{feed} }, $it;
    $self->_render_item($it);
    $self->{txt}->see('end');
}

# one feed item: [type, payload]
sub _render_item {
    my ($self, $it) = @_;
    my ($type, $p) = @$it;
    my $txt = $self->{txt};
    if ($type eq 'user' || $type eq 'assistant') {
        $self->_render_msg($type, $p);
    }
    elsif ($type eq 'umsg') {
        $self->_render_msg('user', $p);
    }
    elsif ($type eq 'live') {
        # the raw streamed reply; the round event replaces it. the mark
        # remembers where it starts so the round can cut it out.
        $txt->markSet('live_at', $txt->index('end-1c'));
        $txt->markGravity('live_at', 'left');
        $txt->insert('end', _decode($p), ['plain']);
        $txt->insert('end', "\n", 'plain');
        $self->{live} = 1;
    }
    elsif ($type eq 'err') {
        $txt->insert('end', _decode($p) . "\n", 'err');
    }
    else {    # note / sys: quiet lines between the messages
        $txt->insert('end', _decode($p) . "\n", 'sys');
    }
}

# a streamed piece arrives: add it to the live reply in place
sub _live_append {
    my ($self, $t) = @_;
    my $f = $self->{feed};
    if (@$f && $f->[-1][0] eq 'live' && $self->{live}) {
        $f->[-1][1] .= $t;
        my $txt = $self->{txt};
        # before the newline that ends the live text, not at 'end'
        $txt->insert('end-2c', _decode($t), ['plain']);
        $txt->see('end');
        return;
    }
    if (@$f && $f->[-1][0] eq 'live') {
        # a live item with no text on screen (after a rebuild mid-stream)
        $f->[-1][1] .= $t;
        $self->_render_all();
        return;
    }
    $self->_append_item(['live', $t]);
}

# the round event: the streamed text (if any) comes off the end and the
# finished reply (markdown, tool lines) goes in its place
sub _replace_live {
    my ($self, $text) = @_;
    my $f = $self->{feed};
    if (@$f && $f->[-1][0] eq 'live') {
        pop @$f;
        if ($self->{live}) {
            # up to end-1c, not end: a range that includes the widget's
            # undeletable final newline makes Tk delete the newline BEFORE
            # the range instead - the one that ends the line above
            $self->{txt}->delete('live_at', 'end-1c');
            $self->{live} = 0;
        }
    }
    $self->_append_item(['assistant', $text]);
}

sub _render_msg {
    my ($self, $role, $text) = @_;
    my $txt = $self->{txt};
    $text = _decode($text);
    if ($role eq 'user') {
        # tool results and nudges are protocol traffic, not things the human
        # typed: give each result a quiet line or two instead of the raw
        # JSON, and skip internal nudges entirely.
        if ($text =~ /^```result\b/s) {
            # the body only: the fence lines are not results
            my (undef, undef, $results) = OldAgent::Protocol::visible($text);
            $self->_render_results($results);
            return;
        }
        if ($text =~ /No tool call was emitted, so nothing was executed/) {
            $txt->insert('end', "  (kept the model moving - no action yet)\n", 'note');
            return;
        }
        $self->_render_user($text);
    } else {
        # the assistant's tool/result fences are protocol, not prose: show
        # the prose as text and one quiet line per tool call
        my ($prose, $tools, $results) = OldAgent::Protocol::visible($text);
        if (!length OldAgent::Util::strip($prose)) {
            # a bare done block: its summary is the reply
            my $summary = _done_summary($tools);
            $prose = $summary if defined $summary;
        }
        if (length OldAgent::Util::strip($prose)) {
            $self->_render_md($prose);
        }
        $self->_render_tools($tools) if length OldAgent::Util::strip($tools);
        $self->_render_results($results) if length OldAgent::Util::strip($results);
    }
}

# the human's message: blue, on the right. the tag covers the newline
# too, so the justify applies to the whole (possibly wrapped) line; with
# no background there is no band to worry about.
sub _render_user {
    my ($self, $text) = @_;
    my $txt = $self->{txt};
    $txt->insert('end', "\n", 'gap');
    $txt->insert('end', $text . "\n", 'user');
    $txt->insert('end', "\n", 'gap');
}

# is a user message the human's (vs a tool result / an internal nudge)?
sub _is_user_bubble {
    my ($self, $text) = @_;
    return 0 if $text =~ /^```result\b/s;
    return 0 if $text =~ /No tool call was emitted, so nothing was executed/;
    return 1;
}

# the agent's prose: markdown, straight into the transcript. fence lines
# (```perl / ```) are markup, not content; the code block's own
# background marks it out.
sub _render_md {
    my ($self, $text) = @_;
    my $txt = $self->{txt};
    for my $line (OldAgent::Textfmt::tokens(_decode($text))) {
        next if @$line == 1 && grep({ $_ eq 'codeblock' } @{ $line->[0][0] })
             && $line->[0][1] =~ /^\s*(?:```+|~~~+)[\w+-]*\s*$/;
        for my $tok (@$line) {
            my ($tags, $str) = @$tok;
            next unless defined $str && length $str;
            # the tag list goes as an ARRAY: a joined "plain,bold" string
            # is one tag of that name to Tk, and nothing renders
            $txt->insert('end', $str, [ @$tags ]);
        }
        $txt->insert('end', "\n", 'plain');
    }
}

# everything on screen as plain text (the smoke test and the diagnostics
# read this)
sub transcript_text {
    my ($self) = @_;
    return $self->{txt}->get('1.0', 'end-1c');
}

# the summary of a done block among the tool lines, if there is one
sub _done_summary {
    my ($tools) = @_;
    for my $t (split(/\n/, defined $tools ? $tools : '')) {
        my ($d, $err) = OldAgent::JSON::decode($t);
        next if $err || ref($d) ne 'HASH' || !defined $d->{tool};
        next unless lc($d->{tool}) eq 'done';
        my $a = ref($d->{args}) eq 'HASH' ? $d->{args} : {};
        my $s = defined $a->{summary} ? $a->{summary} : $a->{message};
        return $s if defined $s && !ref $s && length $s;
    }
    return undef;
}

# one quiet line per tool call, the call in full:
#   [tool] bash  uname -a && cat /etc/os-release
# a long command wraps under itself; only a file body (write/edit
# content) is summarised, as its size.
sub _render_tools {
    my ($self, $tools) = @_;
    my $txt = $self->{txt};
    for my $t (split(/\n/, $tools)) {
        next unless length $t;
        my ($d, $err) = OldAgent::JSON::decode($t);
        if (!$err && ref($d) eq 'HASH' && defined $d->{tool}) {
            # done is the model signing off, not an action worth a line
            next if lc($d->{tool}) eq 'done';
            my $name = $d->{tool};
            my $arg  = $d->{args};
            my @bits;
            if (ref($arg) eq 'HASH') {
                for my $k (sort keys %$arg) {
                    my $v = $arg->{$k};
                    next unless defined $v && !ref $v;
                    $v = OldAgent::Util::strip("$v");
                    if ($k eq 'content' || $k eq 'text' || $k eq 'new') {
                        push @bits, "$k=(" . length($v) . " chars)";
                    } elsif ($k eq 'cmd' || $k eq 'command') {
                        unshift @bits, $v;          # the command itself, bare
                    } else {
                        push @bits, "$k=$v";
                    }
                }
            }
            $txt->insert('end', "[tool] $name" . (@bits ? '  ' . join(' ', @bits) : '') . "\n",
                'tool');
        } else {
            # not JSON (e.g. an <function=...> summary line): show as-is
            $txt->insert('end', '[tool] ' . _decode(OldAgent::Util::strip($t)) . "\n", 'tool');
        }
    }
}

# a tool result: one status line, then the output as a quiet block.
# the first lines are shown in full width; a long output is cut by LINES,
# with a count of what was left out.
my $RESULT_LINES = 20;
sub _render_results {
    my ($self, $results) = @_;
    my $txt = $self->{txt};
    for my $r (split(/\n/, $results)) {
        next unless length $r;
        my ($d, $err) = OldAgent::JSON::decode($r);
        if (!$err && ref($d) eq 'HASH' && defined $d->{tool}) {
            next if lc($d->{tool}) eq 'done';     # the summary was the reply
            my $out = defined $d->{output} ? $d->{output} : '';
            $out = OldAgent::Util::strip($out);
            $txt->insert('end', '[' . $d->{tool} . '] ' . ($d->{ok} ? 'ok' : 'failed')
                . (length $out ? '' : ' (no output)') . "\n", 'tool');
            next unless length $out;
            my @lines = split(/\n/, $out, -1);
            my $more = @lines > $RESULT_LINES ? @lines - $RESULT_LINES : 0;
            splice(@lines, $RESULT_LINES) if $more;
            $txt->insert('end', _decode(join("\n", @lines)) . "\n", 'toolout');
            $txt->insert('end', "($more more lines)\n", 'tool') if $more;
            next;
        }
        $txt->insert('end', '[tool] ' . _decode(OldAgent::Util::strip($r)) . "\n", 'tool');
    }
}

# repaint the whole transcript (new session, undo, load, clear)
sub _redraw {
    my ($self) = @_;
    $self->{feed}   = [];
    $self->{capbuf} = '';
    $self->_render_all();
    $self->_status();
}

# ----------------------------------------------------------------- status --

sub _status {
    my ($self, $msg, $mode) = @_;
    $mode = '' unless defined $mode;
    my $cfg = $self->{cfg};
    my $s = 'session ' . $self->{session}
        . '    ' . $cfg->get('provider') . ' -> ' . $cfg->get('model')
        . '    ' . ($cfg->get('base_url') || 'no base url')
        . '    ' . scalar(@{ $self->{agent}->history() }) . ' messages';
    $s .= '    THINKING...' if $mode eq 'busy';
    $s .= '    ' . $msg if defined $msg && length $msg;
    $self->{stat}->configure(-text => $s);
}

sub _flash {
    my ($self, $s) = @_;
    $self->{stat}->configure(-text => $s);
    $self->{root}->after(2500, sub { $self->_status() if !$self->{busy} });
}

sub main_loop {
    my ($self) = @_;
    Tk::MainLoop();
    return 0;
}

1;
