package OldAgent::Doctor;
# "Does this thing run here?" - prints what the machine has, what oldagent
# will therefore use, and proves the loop works without touching a network.

use strict;
use warnings;

use File::Spec ();
use Config ();
use OldAgent ();
use OldAgent::Util ();
use OldAgent::HTTP ();
use OldAgent::Config ();
use OldAgent::Provider ();
use OldAgent::Agent ();
use OldAgent::Tools ();

sub report {
    my (%a) = @_;
    my $cfg = $a{config};
    my @lines;
    my $ok = 1;

    push @lines, 'oldagent ' . OldAgent::version();
    push @lines, '';
    push @lines, '== machine ==';
    push @lines, '  os        : ' . $^O;
    push @lines, '  uname     : ' . (OldAgent::Util::uname() || 'unknown');
    push @lines, '  host      : ' . (eval { require Sys::Hostname; Sys::Hostname::hostname() } || 'unknown');
    push @lines, '  user      : ' . ($ENV{USER} || $ENV{LOGNAME} || '?');
    push @lines, '  cwd       : ' . OldAgent::Util::cwd();
    push @lines, '  tmpdir    : ' . OldAgent::Util::tmpdir();

    my $v = $];
    my $bad = $v < 5.006 ? ' (too old: need 5.006+)' : '';
    $ok = 0 if $v < 5.006;
    push @lines, '';
    push @lines, '== perl ==';
    push @lines, sprintf('  version   : %.3f%s', $v, $bad);
    push @lines, '  exe       : ' . $^X;
    push @lines, '  threads   : ' . ($Config::Config{useithreads} ? 'yes' : 'no') . ' (not used)';
    push @lines, '  fork      : ' . ($Config::Config{d_fork} ? 'yes' : 'no (bash tool needs it)');

    push @lines, '';
    push @lines, '== http transports (first available wins) ==';
    for my $b (OldAgent::HTTP::backends()) {
        my $plain = OldAgent::HTTP::_have($b, 0) ? 'yes' : 'no';
        my $tls   = OldAgent::HTTP::_have($b, 1) ? 'yes' : 'no';
        my $note  = '';
        $note = '  <- would be used for https' if $tls eq 'yes' && $b ne 'socket';
        $note = '  https not possible with this one' if $tls ne 'yes' && $plain eq 'yes';
        push @lines, sprintf('  %-9s plain:%-4s tls:%-4s%s', $b, $plain, $tls, $note);
    }
    my @avail = OldAgent::HTTP::available('https://example.com');
    if (!@avail) {
        $ok = 0;
        push @lines, '  PROBLEM: no https transport. install curl or wget, or point';
        push @lines, '           base_url at a local http:// proxy (see readme.md).';
    }
    my @plain = OldAgent::HTTP::available('http://example.com');
    push @lines, '  note      : ' . (@plain ? 'plain http works' : 'no plain http either');

    push @lines, '';
    push @lines, '== optional niceties ==';
    for my $t (['curl', 'https + redirects'], ['wget', 'fallback downloader'],
               ['bash', 'shell for the bash tool'], ['sh', 'minimum shell'],
               ['tk', 'Tk binary (optional)'], ['wish', 'Tk binary (optional)']) {
        my $w = OldAgent::Util::which($t->[0]);
        push @lines, sprintf('  %-9s %-28s %s', $t->[0], $t->[1], $w ? $w : '-');
    }
    push @lines, sprintf('  %-9s %-28s %s', 'Term::ReadLine', 'REPL line editing (built-in if absent)',
        (eval { require Term::ReadLine; 1 } ? 'core' : 'no')
        . ((defined $Term::ReadLine::IMPLEMENTATION && $Term::ReadLine::IMPLEMENTATION =~ /^(Gnu|EditLine)$/)
          ? " ($Term::ReadLine::IMPLEMENTATION)" : ', own editor will be used'));
    push @lines, sprintf('  %-9s %-28s %s', 'Tk', 'oa desktop frontend',
        (eval { require Tk; 1 } ? 'present' : 'not installed')
        . (eval { require OldAgent::Desktop; 1 } ? '' : ' (module missing)'));

    push @lines, '';
    push @lines, '== config ==';
    my @files = OldAgent::Config->new->files;
    push @files, $cfg->files if $cfg;
    my $seen = {};
    for my $f (@files) {
        next if $seen->{$f}++;
        push @lines, '  loaded    : ' . $f;
    }
    push @lines, '  none      : (defaults only)' unless $seen && %$seen;
    if ($cfg) {
        my $r = $cfg->redacted;
        for my $k ('provider', 'base_url', 'model', 'api_key', 'http', 'timeout',
                   'approve', 'tools', 'max_turns', 'root') {
            push @lines, sprintf('  %-9s %s', $k, defined $r->{$k} && length $r->{$k} ? $r->{$k} : '-');
        }
    }

    if ($cfg && $a{ping}) {
        push @lines, '';
        push @lines, '== reachability ==';
        my $p = OldAgent::Provider->new(config => $cfg);
        my ($models, $err) = $p->list_models;
        if ($err) {
            push @lines, '  models    : FAILED ' . $err;
            $ok = 0;
        } else {
            push @lines, '  models    : ok, ' . scalar(@$models) . ' listed';
            my @head = @$models > 8 ? @{ $models }[0 .. 7] : @$models;
            push @lines, '              ' . join(', ', @head) . (@$models > 8 ? ' ...' : '');
        }
    }

    push @lines, '';
    push @lines, '== self test (no network) ==';
    my ($pass, $detail) = selftest();
    push @lines, '  agent loop: ' . ($pass ? "ok ($detail)" : "FAILED ($detail)");
    $ok = 0 unless $pass;

    push @lines, '';
    push @lines, $ok ? 'verdict: oldagent should work here.'
                     : 'verdict: something needs fixing before this box can talk to a model.';
    return wantarray ? (\@lines, $ok) : join("\n", @lines) . "\n";
}

# Drive a real agent turn with the built-in echo provider: the "model" asks
# for a bash command and a file write, then finishes.  Exercises protocol,
# JSON, tools, approvals, and the loop.
sub selftest {
    my $dir = File::Spec->catdir(OldAgent::Util::tmpdir(),
                                 sprintf('oldagent-selftest-%d', $$));
    mkdir $dir;
    my $script = File::Spec->catfile($dir, 'script.txt');
    my $target = 'hello.txt';
    OldAgent::Util::spew($script, join("\n----\n",
        "I will make the file.\n```tool\n{\"tool\":\"write\",\"args\":{\"path\":\"$target\",\"content\":\"it works\\n\"}}\n```",
        "Now check it.\n```tool\n{\"tool\":\"read\",\"args\":{\"path\":\"$target\"}}\n```",
        "Done.\n```tool\n{\"tool\":\"done\",\"args\":{\"summary\":\"wrote and read back the file\"}}\n```",
    ) . "\n");

    local $ENV{OA_ECHO_SCRIPT} = $script;
    my $cfg = OldAgent::Config->load(
        no_files   => 1,
        overrides  => { provider => 'echo', approve => 'auto', root => $dir,
                        tools => 1, max_turns => 5 },
    );
    my $agent = OldAgent::Agent->new(config => $cfg, quiet => 1);
    my ($reply, $err) = $agent->ask('make a file that says it works');
    if ($err) {
        _rrmdir($dir);
        return (0, 'agent error: ' . $err);
    }
    my ($data) = OldAgent::Util::slurp(File::Spec->catfile($dir, $target));
    _rrmdir($dir);
    if (!defined $data || $data !~ /it works/) {
        return (0, 'tool output missing: ' . (defined $data ? "'$data'" : 'undef'));
    }
    my $s = $agent->stats;
    return (1, "$s->{turns} turns, $s->{calls} tool calls, file verified");
}

sub _rrmdir {
    my ($d) = @_;
    return unless -d $d;
    if (opendir(my $dh, $d)) {
        for my $f (readdir($dh)) {
            next if $f eq '.' || $f eq '..';
            my $p = File::Spec->catfile($d, $f);
            -d $p ? _rrmdir($p) : unlink($p);
        }
        closedir($dh);
    }
    rmdir $d;
}

1;
