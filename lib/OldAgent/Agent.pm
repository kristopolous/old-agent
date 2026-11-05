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

# how many rounds in a row the model may reply with no tool call before we
# give up. a model that keeps talking instead of acting is not going to act
# on its own; nudge it a few times, then stop. 0 disables the nudge entirely
# (the old behaviour: stop at the first tool-less reply).
my $NO_TOOL_MAX = 3;

sub new {
    my ($class, %a) = @_;
    my $cfg = $a{config} or die "agent needs a config\n";
    my $self = {
        cfg       => $cfg,
        tools     => $a{tools} || OldAgent::Tools->new(
                          root       => $cfg->get('root'),
                          max_output => $cfg->get('max_output'),
                          timeout    => 30,
                          cfg        => $cfg,
                      ),
        provider  => $a{provider} || OldAgent::Provider->new(config => $cfg),
        formatter => $a{formatter},          # optional: sub(visible_text) -> rendered
        token     => $a{token},              # optional: sub(piece) while streaming
        round     => $a{round},              # optional: sub(reply) per assistant turn
        sysmsg    => $a{sysmsg},             # optional: sub(text) per user-role message
                                             #   the loop pushes itself (results, nudges)
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
        . "real computer. When the human asks for something to be done on this "
        . "machine, you do it by emitting tool calls and the system executes "
        . "them for you. When the human is just talking to you, answer in "
        . "plain prose - no tool block needed. Be brief and concrete. Prefer "
        . "short commands and small edits.\n\n";
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
            . "cannot run something - emit the tool block instead. Questions about "
            . "this machine - what it is, what is installed, what is wrong - are "
            . "answered by running a command and reading the result, not from "
            . "memory. Execution stops "
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
        $s .= "  - When a task that used tools is finished, END your final reply with a done block: a single fenced tool block containing {\"tool\":\"done\",\"args\":{\"summary\":\"one paragraph\"}}.\n";
        $s .= "  - Plain prose outside tool blocks is shown to the human. A conversational reply needs no tool block and no done block.\n";
        $s .= "  - Only act on what the human asked for in this conversation. Do not go looking for other work.\n";
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

sub reset { my ($self) = @_; $self->{history} = []; $self->{no_tool} = 0; $self->{stats} = { turns => 0, calls => 0, denied => 0 }; }

# the reminder a model gets when it replies without doing anything: do the
# next step, don't narrate it; and when it is truly finished, say so with a
# done block.
sub _nudge {
    return "No tool call was emitted, so nothing was executed - the task is not "
        . "done yet. Take the next concrete step by emitting a fenced tool "
        . "block now, for example:\n"
        . "  \`\`\`tool\n"
        . "  {\"tool\":\"read\",\"args\":{\"path\":\"fruits.txt\"}}\n"
        . "  \`\`\`\n"
        . "Run or do the step; do not describe it in prose. When the task is "
        . "fully finished, emit {\"tool\":\"done\",\"args\":{\"summary\":\"one "
        . "paragraph\"}}.";
}

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
    $self->{no_tool} = 0;
    return $self->_loop();
}

# does a tool-less reply read like the model narrating a step it meant to
# take ("Let me check...", "I'll read the file...")? that is a stall worth
# a nudge. a plain answer ("Hey! What can I do for you?") is not.
sub _looks_like_intent {
    my ($text) = @_;
    return 0 unless defined $text;
    # "let me know" and "I'll be here" are sign-offs, not steps
    return 1 if $text =~ /\b(?:let me(?! know)|let's|i'll(?! be\b)|i will(?! be\b)|i am going to|i'm going to|i need to|i should|first,? i|next,? i|now i)\b/i;
    return 0;
}

sub _loop {
    my ($self) = @_;
    my $last = '';
    for (my $turn = 1; $turn <= $self->{max_turns}; $turn++) {
        $self->_trim_history;
        my ($reply, $err);
        if (ref($self->{token}) eq 'CODE'
            && $self->{provider}->can('chat_stream')) {
            ($reply, $err) = $self->{provider}->chat_stream(
                system   => $self->system_prompt(),
                messages => $self->{history},
                token    => $self->{token},
            );
        } else {
            ($reply, $err) = $self->{provider}->chat(
                system   => $self->system_prompt(),
                messages => $self->{history},
            );
        }
        if ($err) {
            $self->emit('[oldagent] ' . $err);
            pop @{ $self->{history} } if $turn == 1;
            return (undef, $err);
        }
        $reply = '' unless defined $reply;
        push @{ $self->{history} }, { role => 'assistant', content => $reply };
        $self->{stats}{turns}++;
        $last = $reply;
        $self->{round}->($reply) if ref($self->{round}) eq 'CODE';

        my $shown = _strip_blocks($reply);
        # when a token callback is streaming the reply live, do not print it
        # a second time when the round finishes; the listener has it already.
        if (ref($self->{token}) ne 'CODE'
            && length OldAgent::Util::strip($shown)) {
            $shown = $self->{formatter}->($shown) if ref($self->{formatter}) eq 'CODE';
            $self->emit($shown);
        }

        last unless $self->{tools_on};
        my $calls = OldAgent::Protocol::parse($reply);
        unless (@$calls) {
            # the model replied without a tool call: that is the end of the
            # turn - unless it is narrating a step instead of taking it
            # ("Let me check the file..."). that is a stall: nudge it to
            # act, but give up after a few empty rounds so a stubborn model
            # cannot run the budget down in a circle.
            last unless _looks_like_intent($reply);
            if ($self->{cfg}->get('no_tool_max', $NO_TOOL_MAX) >= 0) {
                $self->{no_tool} = ($self->{no_tool} || 0) + 1;
                if ($self->{no_tool} > $self->{cfg}->get('no_tool_max', $NO_TOOL_MAX)) {
                    $self->emit('[oldagent] the model stopped emitting tool calls; stopping');
                    last;
                }
                push @{ $self->{history} },
                    { role => 'user', content => _nudge(), nudge => 1 };
                $self->{sysmsg}->(_nudge()) if ref($self->{sysmsg}) eq 'CODE';
                next;
            }
            last;
        }
        $self->{no_tool} = 0;

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
        $self->{sysmsg}->($block) if ref($self->{sysmsg}) eq 'CODE';
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
