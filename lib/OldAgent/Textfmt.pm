package OldAgent::Textfmt;
# Markdown-lite in plain perl, no dependencies.
#
# The inline parser is a left-to-right *state machine* (ported from the
# streamdown line_format approach): it tokenizes a line into runs of
# delimiter characters (~~, **_, _**, *{1,3}, _{1,3}, `+) and runs of
# plain text, and carries the active emphasis state (bold / italic /
# underline / strikeout / code) instead of hunting for balanced marker
# pairs.  That is what gives the CommonMark behaviours we actually want:
#
#   * a code span wins, and everything inside it is literal
#   * `*` opens only when left-flanking (not right after a word char) and
#     not immediately followed by a space
#   * `_` opens only when the next char is a word char (the intra-word rule)
#   * `***` / `___` / `**_` / `_**` are bold+italic, `~~` is strikeout
#
# The same token stream feeds two renderers.  Every run is [ \@tags, $text ]
# where \@tags is the full set of tags that apply to that span, so runs are
# self-describing: the terminal renderer opens all the tags, prints the text,
# and resets, and the Tk desktop applies the same tag list to a Text range.

use strict;
use warnings;

# ------------------------------------------------------------- tokens ----

# Returns a list of lines; each line is a list of [ \@tags, $text ] runs.
sub tokens {
    my ($text) = @_;
    $text = '' unless defined $text;
    my @lines = split(/\n/, $text, -1);
    my @out;
    my $fence = '';
    for my $l (@lines) {
        if (!$fence && $l =~ /^\s*(```+|~~~+)\s*[\w+-]*\s*$/) {
            $fence = 1;
            push @out, [ [ ['codeblock'], $l ] ];
            next;
        }
        if ($fence) {
            push @out, [ [ ['codeblock'], $l ] ];
            $fence = '' if $l =~ /^\s*(```+|~~~+)\s*$/;
            next;
        }
        if ($l =~ /^(#{1,6})\s+(.*)$/) {
            my $n = length($1);
            $n = 6 if $n > 6;
            push @out, [ [ ["h$n"], $2 ] ];
            next;
        }
        if ($l =~ /^\s*([-*+]|\d+\.)\s/) {
            push @out, [ _inline($l, 'list') ];
            next;
        }
        if ($l =~ /^>\s?/) {
            push @out, [ _inline($l, 'quote') ];
            next;
        }
        if ($l =~ /^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/) {
            push @out, [ [ ['hr'], $l ] ];
            next;
        }
        if (!length($l)) {
            push @out, [ [ ['plain'], '' ] ];
            next;
        }
        push @out, [ _inline($l, 'plain') ];
    }
    return @out;
}

# ----------------------------------------------------------- state machine

# A "word" character for the flanking tests: ASCII alnum, or a quote /
# backslash.  Everything else (spaces, punctuation, high/UTF-8 bytes) is a
# boundary.  This mirrors streamdown's not_text().
sub _is_word {
    my $c = shift;
    return 0 unless defined $c && length $c;
    return $c =~ /[A-Za-z0-9]/ || $c eq '\\' || $c eq '"' ? 1 : 0;
}

sub _same {
    my ($a, $b) = @_;
    return 0 unless @$a == @$b;
    for my $i (0 .. $#$a) { return 0 if $a->[$i] ne $b->[$i] }
    return 1;
}

# The full tag list for the current state.  A code span suppresses every
# other tag (its content is literal and takes the code styling alone).
sub _calc_tags {
    my ($base, $bold, $italic, $underline, $strike, $code) = @_;
    return ('code') if $code;
    my @t = ($base);
    push @t, 'bold'      if $bold;
    push @t, 'italic'    if $italic;
    push @t, 'underline' if $underline;
    push @t, 'strikeout' if $strike;
    return @t;
}

# Left-to-right inline state machine.  $base is the tag every run starts
# with (plain / quote / list); the emphasis flags layer on top of it.
sub _inline {
    my ($line, $base) = @_;
    my @out;
    my $buf = '';
    my ($bold, $italic, $underline, $strike) = (0, 0, 0, 0);
    my $code = '';                          # backtick run we are inside, or ''
    my @tags;

    my $calc = sub {
        _calc_tags($base, $bold, $italic, $underline, $strike, $code)
    };
    my $flush = sub {
        return unless length $buf;
        push @out, [ [ @tags ], $buf ];
        $buf = '';
    };
    my $set_tags = sub {
        my @new = $calc->();
        return if _same(\@new, \@tags);
        $flush->();
        @tags = @new;
    };

    @tags = $calc->();

    # Alternatives are tried in order at each position, so a code span wins
    # over emphasis, a link wins over a lone [ , and *** wins over **.
    my $re = qr{
          `+                                        # code span delimiters
        | \!\[[^\]]*\]\([^)\s]*\)                   # image
        | \[[^\]]*\]\([^)\s]*\)                     # inline link
        | ~~                                        # strikeout
        | \*\*_|_\*\*|\*\*\*|___                     # bold + italic
        | \*\*|__                                   # bold
        | \*|_                                       # italic and underscore
        | (?!\![^\]]*\]\([^)\s]*\))                 # a ! not starting an image
          (?!\[[^\]]*\]\([^)\s]*\))                  # ...and a [ not a link
          [!\[]                                       #   -> literal ! or [
        | \]                                        # a ]
        | [^~_*`\[\]!]+                             # plain text
    }x;

    while ($line =~ /$re/g) {
        my $tok  = $&;
        my $s    = $-[0];
        my $e    = $+[0];
        my $prev = $s > 0 ? substr($line, $s - 1, 1) : '';
        my $next = $e < length($line) ? substr($line, $e, 1) : '';
        my $notprev = !_is_word($prev);

        if ($tok =~ /^`+$/) {                               # code delimiter run
            if (!$code) {
                $code = $tok;
                $set_tags->();
            }
            elsif ($code eq $tok) {
                $code = '';
                $set_tags->();
            }
            else { $buf .= $tok }                           # mismatched run: literal
            next;
        }
        if ($code) { $buf .= $tok; next }                   # inside code: literal

        if ($tok =~ /\A\!\[([^\]]*)\]\(([^)\s]*)\)\z/) {    # image
            $flush->();
            push @out, [ [ @tags, 'url' ], " <$2>" ];
            next;
        }
        if ($tok =~ /\A\[([^\]]*)\]\(([^)\s]*)\)\z/) {      # link
            $flush->();
            push @out, [ [ @tags, 'link' ], $1 ];
            push @out, [ [ @tags, 'url'  ], " <$2>" ];
            next;
        }

        if ($tok eq '~~' && ($strike || $notprev)) {
            $strike = !$strike;
            $set_tags->();
        }
        elsif ($tok =~ /\A(\*\*_|_\*\*|\*\*\*|___)\z/ && ($bold || $notprev)) {
            $bold = !$bold;
            $italic = !$italic;
            $set_tags->();
        }
        elsif (($tok eq '**' || $tok eq '__') && ($bold || $notprev)) {
            $bold = !$bold;
            $set_tags->();
        }
        elsif ($tok eq '*' && ($italic || ($notprev && $next ne ' '))) {
            $italic = !$italic;
            $set_tags->();
        }
        elsif ($tok eq '_' && ($underline || ($notprev && $next =~ /[A-Za-z0-9]/))) {
            $underline = !$underline;
            $set_tags->();
        }
        else {
            $buf .= $tok;                                  # literal token
        }
    }
    $flush->();
    @out = [ [ ($base), $line ] ] if !@out && length $line;
    return @out;
}

# ---------------------------------------------------------------- ansi ----

# Each tag is [open, close].  Because every run carries its full tag list and
# the next run re-opens everything it needs, a plain reset at the end of a
# run is always safe.  Colours are 8/16-colour terminal safe.
my %CODE = (
    h1 => [ "\e[1;36m", "\e[0m" ],
    h2 => [ "\e[1;33m", "\e[0m" ],
    h3 => [ "\e[1;35m", "\e[0m" ],
    h4 => [ "\e[1;34m", "\e[0m" ],
    h5 => [ "\e[1;35m", "\e[0m" ],
    h6 => [ "\e[1;37m", "\e[0m" ],
    bold      => [ "\e[1m",  "\e[0m" ],
    italic    => [ "\e[3m",  "\e[0m" ],
    underline => [ "\e[4m",  "\e[0m" ],
    strikeout => [ "\e[9m",  "\e[0m" ],
    code      => [ "\e[33m", "\e[0m" ],
    codeblock => [ "\e[36m", "\e[0m" ],
    link      => [ "\e[4;34m", "\e[0m" ],
    url       => [ "\e[2m",    "\e[0m" ],
    quote     => [ "\e[2m",    "\e[0m" ],
    list      => [ '',        ''    ],
    hr        => [ "\e[2m",    "\e[0m" ],
    plain     => [ '',        ''    ],
);

# ansify($text, 1|0) -> string.  With 0 you get the text back unchanged, so
# it is a safe no-op either way.
sub ansify {
    my ($text, $on) = @_;
    return $text unless $on;
    return $text unless defined $text && length $text;
    my @lines = tokens($text);
    my @out;
    for my $line (@lines) {
        my $s = '';
        for my $t (@$line) {
            my ($tags, $str) = @$t;
            my $open = join('', map { $CODE{$_} ? $CODE{$_}[0] : '' } @$tags);
            # NB: build the close with a scalar `if`, not `grep {..} ? :` --
            # the latter is parsed as `grep {..} (@$tags ? "\e[0m" : "")`,
            # i.e. the ternary becomes grep's statement modifier and grep
            # returns a *count* (0/1) instead of the escape.  That used to
            # emit a bare `0` and never close a style, so everything after a
            # code span ran on in its colour.
            my $close = '';
            $close = "\e[0m" if grep { $CODE{$_} && $CODE{$_}[0] ne '' } @$tags;
            $s .= $open . $str . $close;
        }
        push @out, $s;
    }
    return join("\n", @out);
}

# Tags that a Tk Text widget should define, as [tagname, options-hash-ref].
sub tk_tagdefs {
    return (
        h1        => { font => 'Helvetica-Bold 15', fg => '#0033aa' },
        h2        => { font => 'Helvetica-Bold 13', fg => '#0a5200' },
        h3        => { font => 'Helvetica-Bold 12', fg => '#40004d' },
        h4        => { font => 'Helvetica-Bold 11' },
        h5        => { font => 'Helvetica-Bold 11' },
        h6        => { font => 'Helvetica-Bold 11', fg => '#555555' },
        bold      => { font => 'Helvetica-Bold 11' },
        italic    => { font => 'Helvetica-Oblique 11' },
        underline => { underline => 1 },
        strikeout => { overstrike => 1 },
        code      => { font => 'Courier-Bold 11', fg => '#7a0000' },
        codeblock => { font => 'Courier 11', bg => '#eeeeee' },
        link      => { underline => 1, fg => '#0000ee' },
        url       => { fg => '#888888' },
        quote     => { fg => '#555555' },
        list      => {},
        hr        => { fg => '#999999' },
        plain     => { font => 'Helvetica 11' },
    );
}

1;
