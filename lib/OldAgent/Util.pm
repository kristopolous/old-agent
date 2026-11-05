package OldAgent::Util;
# Small helpers. Core modules only, and only ones that existed in 2000.

use strict;
use warnings;

use Cwd ();
use File::Basename ();
use File::Spec ();
use File::Path ();
use POSIX ();
use IPC::Open3 ();

sub cwd {
    my $d = eval { Cwd::cwd() };
    return defined $d ? $d : '.';
}

sub abs_path {
    my ($p) = @_;
    return undef unless defined $p;
    my $a = eval { Cwd::abs_path($p) };
    return $a if defined $a;
    $a = eval { Cwd::realpath($p) };
    return $a if defined $a;
    return rel2abs($p);
}

sub rel2abs {
    my ($p) = @_;
    return $p if File::Spec->file_name_is_absolute($p);
    return File::Spec->rel2abs($p, cwd());
}

sub expand_path {
    my ($p) = @_;
    return undef unless defined $p;
    return home_dir_guess() if $p eq '~';
    if (substr($p, 0, 2) eq '~/') {
        return home_dir_guess() . '/' . substr($p, 2);
    }
    return $p;
}

sub home_dir_guess {
    return $ENV{HOME} || $ENV{USERPROFILE} || cwd();
}

# --- text -----------------------------------------------------------------

sub clip {
    my ($s, $max) = @_;
    $max = 4000 unless defined $max;
    return '' unless defined $s;
    return $s if length($s) <= $max;
    # a short limit (a one-line summary in a transcript) is a plain
    # truncation; keeping head AND tail there produced "d [... clipped 0
    # chars ...] one summary=..." lines. only a long limit keeps a tail.
    if ($max < 400) {
        return substr($s, 0, ($max > 3 ? $max - 3 : $max)) . '...';
    }
    my $keep = $max - 200;
    my $head = substr($s, 0, $keep);
    my $tail = substr($s, -$keep);
    my $gone = length($s) - length($head) - length($tail);
    $gone = 0 if $gone < 0;
    return $head . "\n[... clipped $gone chars ...]\n" . $tail;
}

sub one_line {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/\s+/ /g;
    return $s;
}

sub rstrip { my ($s) = @_; $s = '' unless defined $s; $s =~ s/\s+$//; return $s; }
sub lstrip { my ($s) = @_; $s = '' unless defined $s; $s =~ s/^\s+//; return $s; }
sub strip  { return lstrip(rstrip($_[0])); }

sub starts_with {
    my ($s, $p) = @_;
    return 0 unless defined $s && defined $p;
    return substr($s, 0, length($p)) eq $p;
}

# --- files ----------------------------------------------------------------

sub slurp {
    my ($path) = @_;
    my $fh;
    unless (open($fh, '<', $path)) {
        return (undef, "cannot open $path: $!");
    }
    my $data;
    { local $/; $data = <$fh>; }
    close($fh);
    $data = '' unless defined $data;
    return ($data, undef);
}

sub spew {
    my ($path, $data, $append) = @_;
    my $dir = File::Basename::dirname($path);
    if (length($dir) && !-d $dir) {
        eval { File::Path::mkpath($dir) };
        return "cannot create directory $dir: $@" if $@;
    }
    my $mode = $append ? '>>' : '>';
    my $fh;
    unless (open($fh, $mode, $path)) {
        return "cannot write $path: $!";
    }
    print($fh $data);
    close($fh);
    return undef;
}

sub is_binary {
    my ($s) = @_;
    return 0 unless defined $s && length $s;
    return index($s, "\0") >= 0 ? 1 : 0;
}

# --- temp files (File::Temp is not in perl 5.6.0) -------------------------

sub tmpdir {
    for my $e ('TMPDIR', 'TEMP', 'TMP') {
        my $d = $ENV{$e};
        return $d if $d && -d $d && -w $d;
    }
    return '/tmp' if -d '/tmp' && -w '/tmp';
    return cwd();
}

my $tmpseq = 0;
sub tmpfile {
    my ($tag) = @_;
    $tag = 'tmp' unless defined $tag;
    $tag =~ s/[^A-Za-z0-9_.-]/_/g;
    $tmpseq++;
    return File::Spec->catfile(tmpdir(),
        sprintf('oldagent-%d-%d-%d-%s', $$, time(), $tmpseq, $tag));
}

# --- processes ------------------------------------------------------------

sub _child_exit {
    my ($code) = @_;
    POSIX::_exit($code) if defined &POSIX::_exit;
    exit $code;
}

sub which {
    my ($name) = @_;
    return undef unless defined $name && length $name;
    if ($name =~ m{/}) {
        return -x $name ? $name : undef;
    }
    my $path = $ENV{PATH} || '';
    for my $d (split(/:/, $path)) {
        $d = '.' if $d eq '';
        my $f = File::Spec->catfile($d, $name);
        return $f if -x $f && !-d _;
    }
    return undef;
}

# run_cmd(cmd => ..., cwd => ..., timeout => ..., stdin => ...)
# returns { ok, out, exit, signal, killed, error }
sub run_cmd {
    my (%a) = @_;
    my $cmd     = $a{cmd};
    my $timeout = defined $a{timeout} ? $a{timeout} : 30;
    my $outf    = tmpfile('out');
    my $inf     = undef;

    if (defined $a{stdin}) {
        $inf = tmpfile('in');
        my $err = spew($inf, $a{stdin});
        return { ok => 0, error => $err } if $err;
    }

    my $pid = fork();
    if (!defined $pid) {
        unlink($outf);
        unlink($inf) if defined $inf;
        return { ok => 0, error => "fork failed: $!" };
    }

    if ($pid == 0) {
        eval { POSIX::setpgid(0, 0) };
        eval { chdir($a{cwd}) if defined $a{cwd} && length $a{cwd} };
        if (defined $inf) {
            if (!open(STDIN, '<', $inf)) { _child_exit(127) }
        } else {
            open(STDIN, '<', '/dev/null');
        }
        if (!open(STDOUT, '>', $outf)) { _child_exit(127) }
        open(STDERR, '>&STDOUT');
        my $sh = -x '/bin/sh' ? '/bin/sh' : 'sh';
        { exec { $sh } $sh, '-c', $cmd }
        print STDOUT "oldagent: exec failed: $!\n";
        _child_exit(127);
    }

    my ($killed, $term_sent) = (0, 0);
    my $old_alarm = $SIG{ALRM};
    $SIG{ALRM} = sub {
        $term_sent++;
        if ($term_sent == 1) {
            kill('TERM', -$pid, $pid);
            $killed = 1;
            alarm(3);
        } else {
            kill('KILL', -$pid, $pid);
        }
    };
    alarm($timeout > 0 ? $timeout : 0);
    waitpid($pid, 0);
    alarm(0);
    $SIG{ALRM} = $old_alarm if defined $old_alarm;

    my ($data, $err) = slurp($outf);
    unlink($outf);
    unlink($inf) if defined $inf;

    my $raw = $?;
    my $sig = $raw & 127;
    my $code = ($raw >> 8) & 255;
    return {
        ok     => ($code == 0 && !$killed) ? 1 : 0,
        out    => defined $data ? $data : '',
        exit   => $code,
        signal => $sig,
        killed => $killed,
        error  => defined $err ? $err : '',
    };
}

# capture(argv => [...], stdin => ..., timeout => ...) without a shell.
sub capture {
    my (%a) = @_;
    my @argv = @{ $a{argv} };
    my $timeout = defined $a{timeout} ? $a{timeout} : 30;
    my $outf = tmpfile('out');
    my $errf = tmpfile('err');
    my $inf  = undef;
    if (defined $a{stdin}) {
        $inf = tmpfile('in');
        my $err = spew($inf, $a{stdin});
        return { ok => 0, error => $err } if $err;
    }

    my @fd;
    my ($wtr, $rdr, $err);
    my $pid = eval {
        IPC::Open3::open3(\*OA_IN, \*OA_OUT, \*OA_ERR, @argv);
    };
    if (!$pid) {
        unlink($outf, $errf);
        unlink($inf) if defined $inf;
        return { ok => 0, error => "cannot run $argv[0]: $@" };
    }

    if (defined $inf) {
        my $fh;
        if (open($fh, '<', $inf)) {
            my $buf;
            eval { while (read($fh, $buf, 8192)) { print OA_IN $buf } };
            close($fh);
        }
    }
    close(OA_IN);

    my $old_alarm = $SIG{ALRM};
    my $killed = 0;
    $SIG{ALRM} = sub { $killed = 1; kill('KILL', $pid) };
    alarm($timeout > 0 ? $timeout : 0);
    my $out = do { local $/; <OA_OUT> };
    my $errtext = do { local $/; <OA_ERR> };
    close(OA_OUT); close(OA_ERR);
    waitpid($pid, 0);
    alarm(0);
    $SIG{ALRM} = $old_alarm if defined $old_alarm;
    unlink($inf) if defined $inf;

    my $raw = $?;
    return {
        ok     => ((($raw >> 8) & 255) == 0 && !$killed) ? 1 : 0,
        out    => defined $out ? $out : '',
        err    => defined $errtext ? $errtext : '',
        exit   => ($raw >> 8) & 255,
        signal => $raw & 127,
        killed => $killed,
    };
}

# --- misc -----------------------------------------------------------------

sub uname {
    my @u = eval { POSIX::uname() };
    return '' unless @u;
    return join(' ', @u[0, 1, 2, 4]);
}

sub redact {
    my ($s) = @_;
    return '' unless defined $s;
    return '****' if length($s) <= 8;
    return substr($s, 0, 4) . '...' . substr($s, -4);
}

sub glob_to_regex {
    my ($g) = @_;
    my $re = '';
    for my $c (split(//, $g)) {
        if    ($c eq '*') { $re .= '[^/]*' }
        elsif ($c eq '?') { $re .= '.' }
        elsif ($c eq '.') { $re .= '\.' }
        elsif ($c =~ /[\\\^\$\+\(\)\[\]\{\}\|]/) { $re .= "\\$c" }
        else { $re .= $c }
    }
    return qr/^$re$/;
}

1;
