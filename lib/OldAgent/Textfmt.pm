package OldAgent::Textfmt;
# Markdown-lite, in plain perl, no dependencies.
#
# The same token stream feeds two renderers:
#   ansify()    ANSI escape codes for terminals (old xterms included: 8 colors)
#   tokens()    [tag, text] pairs that the Tk desktop applies as widget tags
#
# It is deliberately small: headings, bold, italic, inline code, fenced
# code, lists, quotes, links, horizontal rules.  Anything it does not
# understand is shown as-is, which is the only honest fallback.

use strict;
use warnings;

# ------------------------------------------------------------- tokenize ---

# Returns a list of lines; each line is a list of [tag, text] tokens.
sub tokens {
    my ($text) = @_;
    $text = '' unless defined $text;
    my @lines = split(/\n/, $text, -1);
    my @out;
    my $fence = '';
    for my $l (@lines) {
        if (!$fence && $l =~ /^\s*(```+|~~~+)\s*[\w+-]*\s*$/) {
            $fence = 1;
            push @out, [ [ 'codeblock', $l ] ];
            next;
        }
        if ($fence) {
            push @out, [ [ 'codeblock', $l ] ];
            $fence = '' if $l =~ /^\s*(```+|~~~+)\s*$/;
            next;
        }
        if ($l =~ /^(#{1,6})\s/) {
            my $n = length($1);
            $n = 6 if $n > 6;
            push @out, [ [ "h$n", $l ] ];
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
            push @out, [ [ 'hr', $l ] ];
            next;
        }
        if (!length($l)) {
            push @out, [ [ 'plain', '' ] ];
            next;
        }
        push @out, [ _inline($l, 'plain') ];
    }
    return @out;
}

# Inline markers, scanned left to right.  The base tag is what non-marked
# text carries, so a bold run inside a quote keeps the quote color.
sub _inline {
    my ($line, $base) = @_;
    my @tok;
    my $re = qr/(\*\*.+?\*\*)|(`[^`]+`)|(\[[^\]]+\]\([^)\s]+\))|(\*[^*\s][^*]*\*)/;
    my $rest = $line;
    while (length $rest) {
        if ($rest =~ m{\G(.*?)$re}gc) {
            my ($pre, $m) = ($1, $2);
            push @tok, [ $base, $pre ] if length $pre;
            if (defined $3) {
                push @tok, [ 'bold', _strip($m, '*', '*') ];
            } elsif (defined $4) {
                push @tok, [ 'code', _strip($m, '`', '`') ];
            } elsif (defined $5) {
                if ($m =~ /^\[([^\]]*)\]\(([^)\s]+)\)$/) {
                    push @tok, [ 'link', $1 ];
                    push @tok, [ 'url', " <$2>" ];
                } else {
                    push @tok, [ $base, $m ];
                }
            } else {
                push @tok, [ 'italic', _strip($m, '*', '*') ];
            }
            $rest = substr($rest, length($pre) + length($m));
        } else {
            push @tok, [ $base, $rest ];
            last;
        }
    }
    @tok = [ [ $base, $line ] ] if !@tok;
    return @tok;
}

sub _strip {
    my ($s, $a, $b) = @_;
    $s =~ s/^\Q$a\E//;
    $s =~ s/\Q$b\E$//;
    return $s;
}

# ---------------------------------------------------------------- ansi ----

my %CODE = (
    h1 => [ "\e[1;36m", "\e[0m" ],
    h2 => [ "\e[1;33m", "\e[0m" ],
    h3 => [ "\e[1;35m", "\e[0m" ],
    h4 => [ "\e[1m",    "\e[0m" ],
    h5 => [ "\e[1m",    "\e[0m" ],
    h6 => [ "\e[1m",    "\e[0m" ],
    bold => [ "\e[1m",  "\e[0m" ],
    italic => [ "\e[3m", "\e[0m" ],
    code => [ "\e[33m", "\e[0m" ],
    codeblock => [ "\e[36m", "\e[0m" ],
    link => [ "\e[4;34m", "\e[0m" ],
    url => [ "\e[2m",   "\e[0m" ],
    quote => [ "\e[2m", "\e[0m" ],
    list => [ "\e[0m",  "\e[0m" ],
    hr => [ "\e[33m",   "\e[0m" ],
    plain => [ '', '' ],
);

# ansify($text, 1|0) -> string.  With 0 you get the text back unchanged,
# already split into lines and rejoined, so it is a safe no-op either way.
sub ansify {
    my ($text, $on) = @_;
    return $text unless $on;
    return $text unless defined $text && length $text;
    my @lines = tokens($text);
    my @out;
    for my $line (@lines) {
        my $s = '';
        for my $t (@$line) {
            my ($tag, $str) = @$t;
            my $c = $CODE{$tag} || $CODE{plain};
            $s .= $c->[0] . $str . $c->[1];
        }
        push @out, $s;
    }
    return join("\n", @out);
}

# Tags that a Tk Text widget should define.  [tagname, options-hash-ref]
sub tk_tagdefs {
    my %base = ();
    return (
        h1     => { font => 'Helvetica-Bold 15', fg => '#0033aa' },
        h2     => { font => 'Helvetica-Bold 13', fg => '#0a5200' },
        h3     => { font => 'Helvetica-Bold 12', fg => '#40004d' },
        h4     => { font => 'Helvetica-Bold 11' },
        h5     => { font => 'Helvetica-Bold 11' },
        h6     => { font => 'Helvetica-Bold 11', fg => '#555555' },
        bold   => { font => 'Helvetica-Bold 11' },
        italic => { font => 'Helvetica-Oblique 11' },
        code   => { font => 'Courier-Bold 11', fg => '#7a0000' },
        codeblock => { font => 'Courier 11', bg => '#eeeeee' },
        link   => { underline => 1, fg => '#0000ee' },
        url    => { fg => '#888888' },
        quote  => { fg => '#555555' },
        hr     => { fg => '#999999' },
        plain  => { font => 'Helvetica 11' },
    );
}

1;
