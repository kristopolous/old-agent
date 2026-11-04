package OldAgent::Term;
# A line editor for terminals that have no real readline behind
# Term::ReadLine (the common case: it falls back to a dumb stub).
#
#   readline($prompt)  one line, wrapped at the window width,
#                      with history (up/down) and light editing
#   addhistory($line)  remember it
#
# Only core perl and the POSIX `stty` utility.  Raw mode is done with
# stty because it exists on every unix since the 1980s and survives
# perls that predate POSIX::Termios.  Everything is restored in an
# END block, so even a hard die leaves the user's shell sane.

use strict;
use warnings;

# every open tty we put into raw mode, so one END block restores them all
my @RAW = ();
END {
    for my $t (@RAW) {
        system('stty', 'icanon', 'isig', 'echo', 'min', '1', 'time', '0')
            if fileno($t);
    }
}

my @TIOC = (0x5413, 0x40087468, 0x20087468);   # TIOCGWINSZ: linux, bsd, darwin

sub new {
    my ($class) = @_;
    my $tty;
    return undef unless open($tty, '+<', '/dev/tty');

    my $self = {
        tty     => $tty,
        cols    => _winsize($tty) || ($ENV{COLUMNS} && $ENV{COLUMNS} > 2 ? $ENV{COLUMNS} : 80),
        history => [],
        _lines  => 0,
    };
    $self->{cols} = 4 if $self->{cols} < 4;
    bless $self, $class;

    push @RAW, $tty;   # the END block above restores the terminal
    return $self;
}

sub _winsize {
    my ($tty) = @_;
    for my $req (@TIOC) {
        my $ws = pack('S4', 0, 0, 0, 0);
        next unless ioctl($tty, $req, $ws);
        my ($rows, $cols) = unpack('S4', $ws);
        return $cols if $cols && $cols > 3;
    }
    # stty as last resort: "rows cols"
    my $sz = `stty size 2>/dev/null`;
    chomp $sz;
    if ($sz =~ /^(\d+)\s+(\d+)$/) {
        return $2 if $2 > 3;
    }
    return undef;
}

# --------------------------------------------------------------- editor --

sub readline {
    my ($self, $prompt) = @_;
    my $tty = $self->{tty};
    return undef unless fileno($tty);

    # raw, no echo, 100ms read timeout (timeout lets us tell Esc from arrows)
    if (system('stty', '-icanon', '-isig', '-echo', 'min', '0', 'time', '1')) {
        # cannot control the terminal; degrade to a plain read
        print $tty $prompt;
        my $l = <$tty>;
        $l =~ s/\n$// if defined $l;
        return $l;
    }

    my $buf = '';
    my $pos = 0;
    my $hidx = -1;
    my $saved = '';
    my @h = @{ $self->{history} };
    my $W = $self->{cols};

    _render($self, $prompt, $buf, $pos, $W);

    while (1) {
        my $c;
        my $n = sysread($tty, $c, 1);
        last unless defined $n;      # real EOF or error: leave
        next if $n == 0;             # the 100ms timeout expired, no key yet

        my $ord = ord($c);

        if ($ord == 27) {                           # escape: maybe an arrow
            my $a = _peek($tty);
            if (defined $a && $a eq '[') {
                my $b = _peek($tty);
                if (defined $b) {
                    if    ($b eq 'A') { _hist($self, \@h, \$hidx, \$buf, \$pos, \$saved, -1) }
                    elsif ($b eq 'B') { _hist($self, \@h, \$hidx, \$buf, \$pos, \$saved, 1) }
                    elsif ($b eq 'C') { $pos++ if $pos < length($buf) }
                    elsif ($b eq 'D') { $pos-- if $pos > 0 }
                    elsif ($b eq 'H') { $pos = 0 }
                    elsif ($b eq 'F') { $pos = length($buf) }
                    _render($self, $prompt, $buf, $pos, $W);
                }
                next;
            }
            next;                                   # bare escape: ignore
        }

        if ($ord == 127 || $ord == 8) {             # backspace
            if ($pos > 0) {
                $buf = substr($buf, 0, $pos - 1) . substr($buf, $pos);
                $pos--;
                _render($self, $prompt, $buf, $pos, $W);
            }
            next;
        }
        if ($ord == 10 || $ord == 13) {            # accept
            print $tty "\r\n";
            $self->{history} = \@h;
            push @h, $buf if length $buf && (!@h || $h[-1] ne $buf);
            splice @h, 0, @h > 200 ? @h - 200 : 0;
            $self->{history} = \@h;
            return $buf;
        }
        if ($ord == 4) {                           # ctrl-d
            last if !length $buf;
            if ($pos < length($buf)) {            # delete char under cursor
                $buf = substr($buf, 0, $pos) . substr($buf, $pos + 1);
                _render($self, $prompt, $buf, $pos, $W);
            }
            next;
        }
        if ($ord == 3) {                           # ctrl-c: abort this line
            print $tty "^C\n";
            $self->{history} = \@h;
            return undef;
        }
        if ($ord == 1) { $pos = 0; _render($self, $prompt, $buf, $pos, $W); next }
        if ($ord == 5) { $pos = length($buf); _render($self, $prompt, $buf, $pos, $W); next }
        if ($ord == 21) { $buf = substr($buf, $pos); $pos = 0;    # ctrl-u
                    _render($self, $prompt, $buf, $pos, $W); next }
        if ($ord == 23) {                          # ctrl-w: kill word
            my $cut = $pos;
            $cut-- while $cut > 0 && substr($buf, $cut - 1, 1) =~ /\s/;
            $cut-- while $cut > 0 && substr($buf, $cut - 1, 1) !~ /\s/;
            $buf = substr($buf, 0, $cut) . substr($buf, $pos);
            $pos = $cut;
            _render($self, $prompt, $buf, $pos, $W);
            next;
        }
        if ($ord == 12) { $tty->print("\e[2J\e[H"); _render($self, $prompt, $buf, $pos, $W); next }
        if ($ord >= 32) {                          # printable (utf-8 bytes pass through)
            $buf = substr($buf, 0, $pos) . $c . substr($buf, $pos);
            $pos++;
            _render($self, $prompt, $buf, $pos, $W);
            next;
        }
    }

    print $tty "\r\n";
    $self->{history} = \@h;
    return undef;
}

sub _peek {
    my ($tty) = @_;
    my $c;
    my $n = sysread($tty, $c, 1);
    return defined $n && $n ? $c : undef;
}

sub _hist {
    my ($self, $h, $hidx, $buf, $pos, $saved, $dir) = @_;
    return unless @$h;
    if ($$hidx < 0) {
        $$saved = $$buf;        # remember what the user was typing
        $$hidx = @$h - 1;
    } elsif ($dir > 0 && $$hidx == @$h - 1) {
        $$hidx = -1;            # past the newest entry: restore typed text
        $$buf = $$saved;
        $$pos = length($$buf);
        return;
    } else {
        $$hidx += $dir;
    }
    $$hidx = 0 if $$hidx < 0;
    $$hidx = @$h - 1 if $$hidx >= @$h;
    $$buf = $h->[$$hidx];
    $$pos = length($$buf);
}

# --------------------------------------------------------------- render --

sub _render {
    my ($self, $prompt, $buf, $pos, $W) = @_;
    my $out = $self->{tty};
    my $display = $prompt . $buf;

    my @phys;
    while (length($display) > $W) {
        push @phys, substr($display, 0, $W);
        $display = substr($display, $W);
    }
    push @phys, $display;
    @phys = ('') unless @phys;

    my $max = scalar(@phys) > $self->{_lines} ? scalar(@phys) : $self->{_lines};
    $max = 1 if $max < 1;

    if ($self->{_lines}) {
        print $out "\r\e[" . ($self->{_lines} - 1) . "A" if $self->{_lines} > 1;
        print $out "\r";
    } else {
        print $out "\r";
    }
    for my $i (0 .. $max - 1) {
        my $l = $i < @phys ? $phys[$i] : '';
        # keep tabs out: they wreck column math
        my $flat = $l; $flat =~ s/\t/'    '/ge;
        print $out $flat . "\e[K";
        print $out "\n" if $i < $max - 1;
    }
    # position the cursor
    my $cidx = length($prompt) + $pos;
    my $pline = 0;
    my $left = $cidx;
    for my $i (0 .. $#phys) {
        if ($left <= length($phys[$i])) { $pline = $i; last }
        $left -= length($phys[$i]);
    }
    my $up = $max - 1 - $pline;
    print $out "\e[" . $up . "A" if $up > 0;
    print $out "\r";
    print $out "\e[" . $left . "C" if $left;
    $self->{_lines} = $max;
}

sub addhistory {
    my ($self, $line) = @_;
    return unless length $line;
    my @h = @{ $self->{history} };
    push @h, $line if !@h || $h[-1] ne $line;
    splice @h, 0, @h > 200 ? @h - 200 : 0;
    $self->{history} = \@h;
    return $self;
}

sub DESTROY {
    my ($self) = @_;
    my $t = $self->{tty};
    if ($t && fileno($t)) {
        system('stty', 'icanon', 'isig', 'echo', 'min', '1', 'time', '0');
        close $t;
    }
}

1;
