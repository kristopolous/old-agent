package OldAgent::Agent;
# The loop: send the transcript, read the reply, run whatever tools it asked
# for, feed the results back, repeat until it says `done` or we run out of
# turns.

use strict;
use warnings;

use File::Spec ();
use OldAgent ();
use OldAgent::JSON ();
use OldAgent::Util ();
use OldAgent::Tools ();
use OldAgent::Protocol ();
use OldAgent::Provider ();

my @NOTES = ('oldagent.md', 'oldagent.local.md', 'AGENTS.md', 'CLAUDE.md');

sub new {
    my ($class, %a) = @_;
    my $cfg = $a{config} or die "agent needs a config\n";
    my $self = {
        cfg       => $cfg,
        tools     => $a{tools} || OldAgent::Tools->new(
                          root       => $cfg->get('root'),
                          max_output => $cfg->get('max_output'),
                          timeout    => 30,
                      ),
        provider  => $a{provider} || OldAgent::Provider->new(config => $cfg),
        formatter => $a{formatter},          # optional: sub(visible_text) -> rendered
        history   => [],
        out       => $a{out} || \*STDOUT,
        approve   => $a{approve},          # code ref or undef
        quiet     => $a{quiet},
        max_turns => $cfg->get('max_turns', 12) || 12,
        tools_on  => $cfg->get('tools') ? 1 : 0,
        notes     => undef,
        stats     => { turns => 0, calls => 0, denied => 0 },
    };
    return bless $self, $class;
}

sub history { return $_[0]{history} }
sub stats   { return $_[0]{stats} }
sub provider { return $_[0]{provider} }
sub tools   { return $_[0]{tools} }

sub set_tools {
    my ($self, $on) = @_;
    $self->{tools_on} = $on ? 1 : 0;
    $self->{cfg}->set(tools => $on ? 1 : 0);
    return $self->{tools_on};
}

sub emit {
    my ($self, @bits) = @_;
    return if $self->{quiet};
    my $fh = $self->{out};
    if (ref($fh) eq 'CODE') { $fh->(@bits, "\n"); return }
    print($fh join('', @bits), "\n");
}

sub system_prompt {
    my ($self) = @_;
    my $cfg = $self->{cfg};
    my $root = $cfg->get('root') || OldAgent::Util::cwd();
    my $s = "";
    $s .= "You are oldagent " . OldAgent::version() . ", an agent running on a "
        . "real computer. You are NOT a chatbot: the way you act is by emitting "
        . "tool calls, and the system executes them for you. Be brief and "
        . "concrete. Prefer short commands and small edits.\n\n";
    $s .= "Environment\n";
    $s .= "  host: " . (OldAgent::Util::uname() || 'unknown') . "\n";
    $s .= "  perl: $]\n";
    $s .= "  cwd:  " . OldAgent::Util::cwd() . "\n";
    $s .= "  root: $root" . ($cfg->get('root') ? " (writes outside root are refused)\n" : "\n");
    $s .= "\n";

    if ($self->{tools_on}) {
        $s .= "How to act\n";
        $s .= "You act by emitting a fenced block tagged tool containing one JSON "
            . "object; the system runs it and returns the result. Never say you "
            . "cannot run something - emit the tool block instead. Execution stops "
            . "at the end of your reply; results arrive in the next message inside a "
            . "```result block as one JSON object per line.\n\n";
        $s .= "  ```tool\n";
        $s .= "  {\"tool\":\"read\",\"args\":{\"path\":\"notes.txt\"}}\n";
        $s .= "  ```\n\n";
        $s .= $self->{tools}->spec();
        $s .= "\nRules\n";
        $s .= "  - One JSON object per tool block. No comments inside the JSON.\n";
        $s .= "  - Never invent or predict a result. Ask, stop, and wait.\n";
        $s .= "  - Read before you write. Use edit for small changes, write for new files.\n";
        $s .= "  - Keep output small: read with from/lines, list with glob, find with a pattern.\n";
        $s .= "  - When the task is finished, emit a done block with a one-paragraph summary.\n";
        $s .= "  - Plain prose outside tool blocks is shown to the human.\n";
    } else {
        $s .= "You have no tools in this session. Answer in plain text only.\n";
    }

    my $notes = $self->notes();
    if (length $notes) {
        $s .= "\nProject notes (from files in the working directory)\n$notes\n";
    }
    my $extra = $cfg->get('system_extra');
    $s .= "\n$extra\n" if defined $extra && length $extra;
    return $s;
}

sub notes {
    my ($self) = @_;
    return $self->{notes} if defined $self->{notes};
    my $out = '';
    for my $n (@NOTES) {
        my $p = File::Spec->catfile(OldAgent::Util::cwd(), $n);
        next unless -f $p;
        my ($data, $err) = OldAgent::Util::slurp($p);
        next if $err;
        $out .= "\n--- $n ---\n" . OldAgent::Util::clip($data, 3000) . "\n";
    }
    $self->{notes} = $out;
    return $out;
}

sub reset { my ($self) = @_; $self->{history} = []; $self->{stats} = { turns => 0, calls => 0, denied => 0 }; }

sub _trim_history {
    my ($self) = @_;
    my $max = $self->{cfg}->get('history_chars') || 48000;
    my $total = 0;
    for my $m (@{ $self->{history} }) {
        $total += length(defined $m->{content} ? $m->{content} : '');
    }
    my $h = $self->{history};
    while ($total > $max && @$h > 2) {
        my $dropped = shift @$h;
        $total -= length(defined $dropped->{content} ? $dropped->{content} : '');
    }
    return;
}

sub undo {
    my ($self) = @_;
    my $h = $self->{history};
    return 0 unless @$h;
    my $n = 0;
    while (@$h) {
        my $last = pop @$h;
        $n++;
        last if $last->{role} eq 'user';
    }
    return $n;
}

# ask(text) -> reply text (last assistant message)
sub ask {
    my ($self, $text) = @_;
    push @{ $self->{history} }, { role => 'user', content => $text };
    return $self->_loop();
}

sub _loop {
    my ($self) = @_;
    my $last = '';
    for (my $turn = 1; $turn <= $self->{max_turns}; $turn++) {
        $self->_trim_history;
        my ($reply, $err) = $self->{provider}->chat(
            system   => $self->system_prompt(),
            messages => $self->{history},
        );
        if ($err) {
            $self->emit('[oldagent] ' . $err);
            pop @{ $self->{history} } if $turn == 1;
            return (undef, $err);
        }
        $reply = '' unless defined $reply;
        push @{ $self->{history} }, { role => 'assistant', content => $reply };
        $self->{stats}{turns}++;
        $last = $reply;

        my $shown = _strip_blocks($reply);
        if (length OldAgent::Util::strip($shown)) {
            $shown = $self->{formatter}->($shown) if ref($self->{formatter}) eq 'CODE';
            $self->emit($shown);
        }

        last unless $self->{tools_on};
        my $calls = OldAgent::Protocol::parse($reply);
        last unless @$calls;

        my @results;
        my $finished;
        for my $c (@$calls) {
            my $r = $self->_run_one($c);
            push @results, $r;
            $finished = $r if $r->{done};
            last if $finished;
        }
        my $block = OldAgent::Protocol::results_block(\@results);
        push @{ $self->{history} }, { role => 'user', content => $block };
        last if $finished;
    }
    return ($last, undef);
}

sub _run_one {
    my ($self, $call) = @_;
    my $name = $call->{tool};
    my $args = $call->{args};
    $self->{stats}{calls}++;
    $self->emit('[tool] ' . $name . ' ' . OldAgent::Util::clip(_args_line($args), 160));

    if ($name eq 'bash' && !$self->_approved($args)) {
        $self->{stats}{denied}++;
        $self->emit('[tool] denied by human');
        return { tool => 'bash', ok => 0,
                 output => 'the human said no to that command. pick another approach.' };
    }
    my $r = $self->{tools}->call($name, $args);
    $r->{args} = $args;
    return $r;
}

sub _args_line {
    my ($args) = @_;
    return '' unless ref($args) eq 'HASH';
    my @p;
    for my $k (sort keys %$args) {
        my $v = OldAgent::JSON::plain($args->{$k});
        $v = OldAgent::Util::one_line($v);
        $v = substr($v, 0, 60) . '...' if length($v) > 63;
        push @p, "$k=$v";
    }
    return join(' ', @p);
}

sub _approved {
    my ($self, $args) = @_;
    my $mode = $self->{cfg}->get('approve') || 'ask';
    return 1 if $mode eq 'auto' || $mode eq 'off';
    my $cmd = OldAgent::JSON::plain($args->{cmd} || $args->{command} || '');
    if ($self->{approve}) {
        return $self->{approve}->($cmd) ? 1 : 0;
    }
    my $tty = -t STDIN ? 1 : 0;
    if (!$tty) {
        # non-interactive: refuse unless the human opted in
        return 0;
    }
    my $fh = $self->{out};
    print($fh "\nabout to run: $cmd\n");
    print($fh 'allow? [y]es / [n]o / [a]lways : ');

    # the REPL's line editor leaves the tty in raw mode with a short read
    # timeout, so a plain <STDIN> would return immediately (empty) and we
    # would auto-deny before the human can answer.  restore canonical,
    # echo-on line mode for the duration of the read so it actually blocks
    # until the user types a line; the editor re-enters raw mode next round.
    my $raw = 0;
    if (open(my $t, '+<', '/dev/tty')) {
        my $was = `stty -a 2>/dev/null`;
        $raw = ($was =~ /-icanon/) ? 1 : 0;
        system('stty', 'icanon', 'echo', 'isig', 'min', '1', 'time', '0');
    }
    my $ans = <STDIN>;
    $raw && system('stty', '-icanon', '-echo', 'min', '0', 'time', '1');

    $ans = '' unless defined $ans;
    $ans =~ s/\s+$//;
    $ans = lc(substr($ans, 0, 1));
    if ($ans eq 'a') {
        $self->{cfg}->set(approve => 'auto');
        return 1;
    }
    return $ans eq 'y' ? 1 : 0;
}

sub _strip_blocks {
    my ($text) = @_;
    my @lines = split(/\n/, $text, -1);
    my @out;
    my $skip = 0;
    my $marker;
    for my $l (@lines) {
        if (!$skip && $l =~ /^\s*(```+|~~~+)\s*(tool|json|oldagent|oa)?\s*$/) {
            $skip = 1;
            $marker = $1;
            next;
        }
        if ($skip) {
            $skip = 0 if $l =~ /^\s*\Q$marker\E\s*$/;
            next;
        }
        next if $l =~ /^\s*(?:TOOL|OA|oldagent)\s*:\s*\{.*\}\s*$/;
        push @out, $l;
    }
    return join("\n", @out);
}

1;
