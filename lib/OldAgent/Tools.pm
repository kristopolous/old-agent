package OldAgent::Tools;
# The hands: read, write, edit, list, find, bash.  Nothing fancy, nothing
# that needs a module that did not exist in 2001.

use strict;
use warnings;

use File::Basename ();
use File::Spec ();
use File::Path ();
use OldAgent::Util ();

my %ARGS = (
    read  => 'path [from] [lines]',
    write => 'path content [mode]',
    edit  => 'path find replace [all]',
    list  => 'path [glob] [limit]',
    find  => 'pattern [path] [glob] [limit]',
    bash  => 'command [timeout]',
    done  => 'summary',
);

my @ORDER = ('read', 'write', 'edit', 'list', 'find', 'bash', 'done');

my %HELP = (
    read  => 'read a text file; from = first line (1-based), lines = how many',
    write => 'create or overwrite a file, mode=append to add to the end',
    edit  => 'replace the exact text find with replace (all=1 for every match)',
    list  => 'list a directory, optional glob like *.c',
    find  => 'search file contents for a regular expression',
    bash  => 'run a shell command, stdout+stderr merged, default timeout 30s',
    done  => 'call this when the task is finished',
);

sub new {
    my ($class, %a) = @_;
    my $self = {
        root       => $a{root},
        max_output => defined $a{max_output} ? $a{max_output} : 4000,
        timeout    => defined $a{timeout} ? $a{timeout} : 30,
    };
    $self->{root} = OldAgent::Util::abs_path($self->{root}) if $self->{root};
    # a working root is also where relative paths and commands live
    $self->{cwd} = defined $a{cwd} ? $a{cwd}
               : ($self->{root} ? $self->{root} : OldAgent::Util::cwd());
    return bless $self, $class;
}

sub names { return @ORDER }

sub spec {
    my ($self) = @_;
    my $s = "Tools you can use (one JSON object per ```tool block):\n";
    for my $n (@ORDER) {
        $s .= sprintf("  %-6s {\"tool\":\"%s\",\"args\":{%s}}\n", $n, $n, $ARGS{$n});
        $s .= "         $HELP{$n}\n";
    }
    return $s;
}

sub call {
    my ($self, $name, $args) = @_;
    $args = {} unless ref($args) eq 'HASH';
    $name = lc($name || '');
    $name =~ s/^oldagent[.:-]//;
    my %alias = (
        'cat' => 'read', 'view' => 'read', 'show' => 'read',
        'save' => 'write', 'create' => 'write',
        'ls' => 'list', 'dir' => 'list', 'grep' => 'find', 'search' => 'find',
        'shell' => 'bash', 'exec' => 'bash', 'run' => 'bash', 'sh' => 'bash',
        'finish' => 'done', 'complete' => 'done', 'submit' => 'done',
        'get' => 'fetch', 'download' => 'fetch', 'url' => 'fetch',
    );
    $name = $alias{$name} if $alias{$name};
    my $m = "tool_$name";
    if (!$name || !$self->can($m)) {
        return { ok => 0, tool => $name || '?',
                 output => 'unknown tool "' . ($name || '') . '". try again with one of: '
                          . join(', ', $self->names) };
    }
    my $r = eval { $self->$m($args) };
    if ($@) {
        my $err = $@;
        $err =~ s/ at .*? line \d+.*$//s;
        return { ok => 0, tool => $name, output => "tool crashed: $err" };
    }
    $r->{tool} = $name unless defined $r->{tool};
    $r->{output} = OldAgent::Util::clip($r->{output}, $self->{max_output});
    return $r;
}

# ------------------------------------------------------------- plumbing ---

sub _path {
    my ($self, $p, $want) = @_;
    return (undef, 'missing "path" argument') unless defined $p && length $p;
    $p = OldAgent::Util::expand_path($p);
    my $abs = File::Spec->file_name_is_absolute($p)
        ? OldAgent::Util::abs_path($p)
        : OldAgent::Util::abs_path(File::Spec->catfile($self->{cwd}, $p));
    if ($self->{root}) {
        my $root = $self->{root};
        $root =~ s{/$}{};
        my $check = $abs;
        $check = OldAgent::Util::abs_path($abs) if -e $abs;
        if (!OldAgent::Util::starts_with($check, "$root/") && $check ne $root) {
            return (undef, "refused: $abs is outside the working root $root");
        }
    }
    return ($abs, undef);
}

# the path argument, tolerant of the names models actually use
sub _path_arg {
    my ($self, $a) = @_;
    for my $k ('path', 'file', 'filename', 'file_path', 'filepath', 'p', 'file_name', 'filepath', 'location') {
        return $a->{$k} if defined $a->{$k} && length $a->{$k};
    }
    return undef;
}

sub _int {
    my ($v, $d) = @_;
    return $d unless defined $v;
    return $d unless "$v" =~ /^-?\d+$/;
    return $v + 0;
}

sub _bool {
    my ($v) = @_;
    return 0 unless defined $v;
    return ("$v" =~ /^(?:1|true|yes|y|on)$/i) ? 1 : 0;
}

# --------------------------------------------------------------- tools ----

sub tool_read {
    my ($self, $a) = @_;
    my ($path, $err) = $self->_path($self->_path_arg($a));
    return { ok => 0, output => $err } if $err;
    return { ok => 0, output => "no such file: $path" } unless -e $path;
    return { ok => 0, output => "not a file: $path" }   if -d $path;

    my ($data, $oerr) = OldAgent::Util::slurp($path);
    return { ok => 0, output => $oerr } if $oerr;
    if (OldAgent::Util::is_binary($data)) {
        return { ok => 0, output => "$path looks binary; use bash with od/hexdump" };
    }
    my @lines = split(/\n/, $data, -1);
    my $total = scalar(@lines);
    my $from  = _int($a->{from} || $a->{start_line} || $a->{offset}, 1);
    $from = 1 if $from < 1;
    my $count = _int($a->{lines} || $a->{count} || $a->{limit}, 200);
    $count = 1 if $count < 1;
    $count = 2000 if $count > 2000;
    return { ok => 0, output => "file has $total lines, nothing at line $from" }
        if $from > $total && $total > 0;
    my @slice = @lines[ $from - 1 .. ($from - 1 + $count - 1) ];
    @slice = grep { defined } @slice;
    my $end = $from + scalar(@slice) - 1;
    my $head = "# $path lines $from-$end of $total\n";
    $head .= "# (re-read with from=" . ($end + 1) . " for more)\n"
        if $end < $total;
    return { ok => 1, output => $head . join("\n", @slice) };
}

sub tool_write {
    my ($self, $a) = @_;
    my ($path, $err) = $self->_path($self->_path_arg($a));
    return { ok => 0, output => $err } if $err;
    my $content = $a->{content};
    $content = $a->{text} if !defined $content && defined $a->{text};
    return { ok => 0, output => 'missing "content" argument' } unless defined $content;
    my $append = (defined $a->{mode} && lc("$a->{mode}") eq 'append') ? 1 : 0;
    my $existed = -e $path ? 1 : 0;
    my $werr = OldAgent::Util::spew($path, $content, $append);
    return { ok => 0, output => $werr } if $werr;
    my $verb = $append ? 'appended to' : ($existed ? 'overwrote' : 'created');
    return { ok => 1, output => "$verb $path (" . length($content) . " bytes)" };
}

sub tool_edit {
    my ($self, $a) = @_;
    my ($path, $err) = $self->_path($self->_path_arg($a));
    return { ok => 0, output => $err } if $err;
    return { ok => 0, output => "no such file: $path" } unless -f $path;
    my ($find, $replace);
    $find    = defined $a->{find}    ? $a->{find}    : $a->{old};
    $replace = defined $a->{replace} ? $a->{replace} : $a->{new};
    $replace = '' unless defined $replace;
    return { ok => 0, output => 'missing "find" argument' } unless defined $find;
    return { ok => 0, output => '"find" is empty; refusing to guess' } if $find eq '';

    my ($data, $oerr) = OldAgent::Util::slurp($path);
    return { ok => 0, output => $oerr } if $oerr;

    my $count = () = $data =~ /\Q$find\E/g;
    if (!$count) {
        my $loose = $find;
        $loose =~ s/[ \t]+/ /g;
        return { ok => 0, output => "text not found in $path ($count matches). "
                                  . 'read the file again and copy the exact text.' };
    }
    if ($count > 1 && !_bool($a->{all})) {
        return { ok => 0, output => "\"find\" matches $count times in $path; "
                                  . 'make it unique or pass all=1' };
    }
    my $out = $data;
    if (_bool($a->{all})) {
        my $p = 0;
        while (1) {
            my $i = index($out, $find, $p);
            last if $i < 0;
            substr($out, $i, length($find)) = $replace;
            $p = $i + length($replace);
        }
    } else {
        my $i = index($out, $find);
        substr($out, $i, length($find)) = $replace;
    }
    my $werr = OldAgent::Util::spew($path, $out);
    return { ok => 0, output => $werr } if $werr;
    return { ok => 1, output => "edited $path ($count occurrence(s) replaced)" };
}

sub tool_list {
    my ($self, $a) = @_;
    my ($path, $err) = $self->_path($self->_path_arg($a) || '.');
    return { ok => 0, output => $err } if $err;
    return { ok => 0, output => "not a directory: $path" } unless -d $path;
    my $glob  = $a->{glob};
    my $limit = _int($a->{limit}, 200);
    my $re    = $glob ? OldAgent::Util::glob_to_regex($glob) : undef;
    my $dh;
    opendir($dh, $path) or return { ok => 0, output => "cannot list $path: $!" };
    my @names = sort grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh);
    my @out;
    for my $n (@names) {
        next if $re && $n !~ $re;
        my $full = File::Spec->catfile($path, $n);
        my @st = stat($full);
        my $isdir = -d $full ? '/' : '';
        my $size  = @st ? $st[7] : 0;
        push @out, sprintf('%10d %s%s', $size, $n, $isdir);
    }
    my $total = scalar(@out);
    my $more = $total > $limit ? $total - $limit : 0;
    @out = @out[0 .. $limit - 1] if $more;
    return { ok => 1, output => "$path ($total entries)\n"
                              . join("\n", @out)
                              . ($more ? "\n[... $more more, use glob to narrow]" : '') };
}

sub tool_find {
    my ($self, $a) = @_;
    my $pattern = $a->{pattern} || $a->{regex} || $a->{query};
    return { ok => 0, output => 'missing "pattern" argument' } unless defined $pattern;
    my $re = eval { qr/$pattern/ };
    return { ok => 0, output => "bad regex: $@" } if $@;
    my ($path, $err) = $self->_path($self->_path_arg($a) || '.');
    return { ok => 0, output => $err } if $err;
    my $glob  = $a->{glob};
    my $re_g  = $glob ? OldAgent::Util::glob_to_regex($glob) : undef;
    my $limit = _int($a->{limit}, 60);
    my @files;
    if (-f $path) {
        @files = ($path);
    } else {
        @files = _walk($path, 4000);
    }
    my @hits;
    for my $f (@files) {
        last if @hits >= $limit;
        next unless -f $f;
        my $base = File::Basename::basename($f);
        next if $base =~ /^(?:core|.*\.o|.*\.a)$/;
        next if $f =~ m{/\.git/};
        next if $re_g && $base !~ $re_g;
        my @st = stat($f);
        next if @st && $st[7] > 2_000_000;
        my ($data, $oerr) = OldAgent::Util::slurp($f);
        next if $oerr || OldAgent::Util::is_binary($data);
        my $n = 0;
        for my $line (split(/\n/, $data)) {
            $n++;
            if ($line =~ $re) {
                push @hits, "$f:$n:" . OldAgent::Util::clip($line, 200);
                last if @hits >= $limit;
            }
        }
    }
    return { ok => 1, output => @hits
        ? scalar(@hits) . " match(es) for /$pattern/\n" . join("\n", @hits)
        : "no matches for /$pattern/" };
}

sub _walk {
    my ($dir, $cap) = @_;
    my @out;
    my @stack = ($dir);
    while (@stack && @out < $cap) {
        my $d = pop @stack;
        my $dh;
        next unless opendir($dh, $d);
        for my $n (sort readdir($dh)) {
            next if $n eq '.' || $n eq '..';
            my $full = File::Spec->catfile($d, $n);
            if (-d $full) {
                push @stack, $full unless $n =~ /^(?:\.git|\.svn|CVS|node_modules|blib)$/;
            } else {
                push @out, $full;
                last if @out >= $cap;
            }
        }
        closedir($dh);
    }
    return @out;
}

sub tool_fetch {
    my ($self, $a) = @_;
    my $url = $a->{url};
    $url = $a->{uri} if !defined $url && defined $a->{uri};
    return { ok => 0, output => 'missing "url" argument' }
        unless defined $url && length $url;
    $url = "http://$url" unless $url =~ m{^https?://}i;
    my $md  = _bool($a->{markdown});
    my $max = _int($a->{max_bytes}, $a->{max_chars});
    $max = 0 if !defined $max || $max < 1;
    my $proxy = $self->{cfg} ? $self->{cfg}->get('proxy') : '';
    my $is_https = ($url =~ /^https:/i) ? 1 : 0;

    # https through the proxy (the box itself has no TLS)
    if ($is_https && $proxy) {
        eval { require OldAgent::Proxy; 1 };
        if ($@) {
            return { ok => 0, output => "proxy module unavailable: $@" };
        }
        my ($text, $err) = OldAgent::Proxy::fetch($self->{cfg}, $proxy, $url,
            format => ($md ? 'markdown' : 'text'),
            max_bytes => ($max ? $max : 20000),
            timeout => 120);
        return { ok => 0, output => "proxy fetch failed: $err" } if $err;
        return { ok => 1, output => $text };
    }

    # http (or https with no proxy) via the box's own backends
    require OldAgent::HTTP;
    my $r = OldAgent::HTTP::request(
        url => $url, method => 'GET',
        headers => { 'User-Agent' => 'oldagent/0.1' },
        timeout => 60,
    );
    if (!$r->{ok} || ($r->{status} && ($r->{status} < 200 || $r->{status} > 299))) {
        return { ok => 0, output => "fetch failed: " . ($r->{error} || "http $r->{status}") };
    }
    my $body = defined $r->{content} ? $r->{content} : '';
    if ($md) {
        # crude html -> text: strip tags and collapse whitespace
        $body =~ s|<script\b[^>]*>.*?</script>||is;
        $body =~ s|<style\b[^>]*>.*?</style>||is;
        $body =~ s/<[^>]+>/\n/g;
        $body =~ s/&nbsp;/ /g;
        $body =~ s/&amp;/&/g;
        $body =~ s/&lt;/</g;
        $body =~ s/&gt;/>/g;
        $body =~ s/&quot;/"/g;
        $body =~ s/&#39;/'/g;
        $body =~ s/\n\s*\n/\n\n/g;
        $body =~ s/^[ \t\r]+//gm;
        $body =~ s/ +/ /g;
    }
    $body = substr($body, 0, $max) if $max && length($body) > $max;
    $body = OldAgent::Util::rstrip($body);
    $body = '(no content)' unless length $body;
    return { ok => 1, output => $body };
}

sub tool_bash {
    my ($self, $a) = @_;
    my $cmd = $a->{cmd};
    $cmd = $a->{command} if !defined $cmd && defined $a->{command};
    $cmd = $a->{script}  if !defined $cmd && defined $a->{script};
    return { ok => 0, output => 'missing "cmd" argument' }
        unless defined $cmd && length $cmd;
    my $to = _int($a->{timeout}, $self->{timeout});
    $to = 10 if $to < 1;
    $to = 600 if $to > 600;
    my $r = OldAgent::Util::run_cmd(
        cmd => $cmd, cwd => $self->{cwd}, timeout => $to,
    );
    if ($r->{error}) {
        return { ok => 0, output => $r->{error} };
    }
    my $out = OldAgent::Util::rstrip($r->{out});
    my $note = '';
    if ($r->{killed}) {
        $note = "\n[command timed out after ${to}s and was killed]";
    } elsif ($r->{signal}) {
        $note = "\n[killed by signal $r->{signal}]";
    } elsif ($r->{exit} != 0) {
        $note = "\n[exit status $r->{exit}]";
    }
    $out = '(no output)' unless length $out;
    return { ok => ($r->{exit} == 0 && !$r->{killed}) ? 1 : 0,
             output => OldAgent::Util::rstrip($out) . $note };
}

sub tool_done {
    my ($self, $a) = @_;
    my $s = $a->{summary};
    $s = $a->{message} if !defined $s && defined $a->{message};
    $s = '(no summary given)' unless defined $s && length $s;
    return { ok => 1, done => 1, output => $s };
}

1;
