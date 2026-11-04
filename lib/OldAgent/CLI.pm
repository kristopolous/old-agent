package OldAgent::CLI;
# Command line and the terminal REPL.  Deliberately plain: it has to look at
# home in a 80x25 xterm and a /dev/tty over a 9600 baud modem.

use strict;
use warnings;

use Getopt::Long ();
use File::Spec ();
use File::Basename ();
use OldAgent ();
use OldAgent::Util ();
use OldAgent::Config ();
use OldAgent::Provider ();
use OldAgent::Tools ();
use OldAgent::Agent ();
use OldAgent::Doctor ();
use OldAgent::JSON ();
use OldAgent::Textfmt ();

# Render a model's visible reply with markdown-lite colours, but only when it
# is going to a real terminal and the user did not ask for quiet output.  The
# hook stays in the presentation layer: the Agent itself always emits plain
# text, and the tool/error lines never pass through it.
sub _md_formatter {
    my ($a) = @_;
    return undef if $a->{quiet} || !-t STDOUT;
    return sub { OldAgent::Textfmt::ansify($_[0], 1) };
}

my %FLAGS = (
    'provider=s'   => 'provider',
    'base-url=s'   => 'base_url',
    'model=s'      => 'model',
    'key=s'        => 'api_key',
    'http=s'       => 'http',
    'timeout=i'    => 'timeout',
    'turns=i'      => 'max_turns',
    'temperature=f'=> 'temperature',
    'max-tokens=i' => 'max_tokens',
    'root=s'       => 'root',
    'system=s'     => 'system_extra',
    'exec=s'       => 'exec_cmd',
);

my %PLAIN = (
    'yes|y'     => ['approve', 'auto'],
    'ask'       => ['approve', 'ask'],
    'no-tools'  => ['tools', '0'],
    'quiet|q'   => ['quiet', '1'],
    'verbose'   => ['verbose', '1'],
);

sub run {
    my (%a) = @_;
    my @argv = @{ $a{argv} || [] };

    my %ov;
    my %plain;
    my $getopt = Getopt::Long::GetOptionsFromArray(
        \@argv,
        (map { $_ => \$ov{ $FLAGS{$_} } } keys %FLAGS),
        (map { $_ => \$plain{$_} } keys %PLAIN),
        'no-config'   => \my $no_config,
        'config=s'    => \my $config_file,
        'cd=s'        => \my $cd,
        'file|F=s'    => \my @files,
        'help|h'      => \my $help,
        'version|V'   => \my $version,
    );
    return _usage() unless $getopt;

    for my $p (keys %plain) {
        next unless defined $plain{$p};      # Getopt autovivifies the keys
        my ($k, $v) = @{ $PLAIN{$p} };
        $ov{$k} = $v;
    }
    my $quiet = delete $ov{quiet};
    my $verbose = delete $ov{verbose};

    if ($version) { print "oldagent " . OldAgent::version() . " (perl $])\n"; return 0 }

    my $cmd = shift @argv;
    $cmd = 'chat' unless defined $cmd;
    if ($help && ($cmd eq 'help' || !@argv)) { print _usage(); return 0 }

    if ($cd) {
        chdir($cd) or do { print STDERR "oldagent: cannot cd $cd: $!\n"; return 2 };
    }

    my %load = ();
    $load{no_files} = 1 if $no_config;
    if ($config_file) {
        $ENV{OLDAGENT_CONFIG} = $config_file;
    }
    my $cfg = OldAgent::Config->load(overrides => \%ov, %load);
    $ENV{OA_VERBOSE} = 1 if $verbose;

    my %dispatch = (
        chat     => \&cmd_chat,
        repl     => \&cmd_chat,
        ask      => \&cmd_ask,
        a        => \&cmd_ask,
        do       => \&cmd_do,
        run      => \&cmd_do,
        one      => \&cmd_do,
        doctor   => \&cmd_doctor,
        'check' => \&cmd_doctor,
        config   => \&cmd_config,
        models   => \&cmd_models,
        tools    => \&cmd_tools,
        help     => \&cmd_help,
        version  => \&cmd_version,
        desktop  => \&cmd_desktop,
        gui      => \&cmd_desktop,
    );
    my $fn = $dispatch{ lc($cmd) };
    if (!$fn) {
        print STDERR "oldagent: unknown command '$cmd'\n\n" . _usage();
        return 2;
    }
    return $fn->(
        command => $cmd, config => $cfg, argv => \@argv, quiet => $quiet,
        files  => \@files, verbose => $verbose,
    );
}

# ------------------------------------------------------------- commands ---

sub cmd_ask {
    my (%a) = @_;
    my $text = join(' ', @{ $a{argv} });
    $text = _read_stdin() if !$text;
    $text = _attach_files($a{files}, $text);
    return _usage() unless length $text;
    my $cfg = $a{config};
    $cfg->set(tools => 0);
    my $agent = OldAgent::Agent->new(config => $cfg, quiet => $a{quiet}, formatter => _md_formatter(\%a));
    my ($reply, $err) = $agent->ask($text);
    if ($err) { print STDERR "oldagent: $err\n"; return 1 }
    return 0;
}

sub cmd_do {
    my (%a) = @_;
    my $text = join(' ', @{ $a{argv} });
    $text = _read_stdin() if !$text;
    $text = _attach_files($a{files}, $text);
    return _usage() unless length $text;
    my $cfg = $a{config};
    $cfg->set(tools => 1);
    my $agent = OldAgent::Agent->new(config => $cfg, quiet => $a{quiet}, formatter => _md_formatter(\%a));
    my ($reply, $err) = $agent->ask($text);
    if ($err) { print STDERR "oldagent: $err\n"; return 1 }
    return 0;
}

sub cmd_chat {
    my (%a) = @_;
    my $cfg = $a{config};
    my $agent = OldAgent::Agent->new(config => $cfg, formatter => _md_formatter(\%a));
    my $first = join(' ', @{ $a{argv} });
    if (length $first) {
        $first = _attach_files($a{files}, $first);
        my ($reply, $err) = $agent->ask($first);
        if ($err) { print STDERR "oldagent: $err\n"; return 1 }
        return 0 unless -t STDIN;
    }
    # 'oa repl' asks for the session explicitly, so honor it even when
    # stdin is a pipe (scripts, tests, tmux, a dumb screen)
    return 0 unless -t STDIN || ($a{command} || '') eq 'repl';
    return repl(agent => $agent, config => $cfg);
}

sub cmd_doctor {
    my (%a) = @_;
    my $ping = grep { /^--?ping$|^ping$/ } @{ $a{argv} };
    my ($lines, $ok) = OldAgent::Doctor::report(config => $a{config}, ping => $ping);
    print(join("\n", @$lines) . "\n");
    return $ok ? 0 : 1;
}

sub cmd_config {
    my (%a) = @_;
    my $sub = lc($a{argv}[0] || 'show');
    my $cfg = $a{config};
    if ($sub eq 'init') {
        my $path = $a{argv}[1] || (OldAgent::Util::cwd() . '/oldagentrc');
        my $err = $cfg->write_file($path);
        if ($err) { print STDERR "oldagent: $err\n"; return 1 }
        print "wrote $path\n";
        print "now set provider / base_url / model, and api_key if you have one\n";
        return 0;
    }
    if ($sub eq 'path') {
        my @f = $cfg->files;
        print($_ . "\n") for @f;
        print "(no config file found; using defaults and environment)\n" unless @f;
        print "would write: " . OldAgent::Util::cwd() . "/oldagentrc\n";
        return 0;
    }
    my $r = $cfg->redacted;
    for my $k (sort keys %$r) {
        my $v = $r->{$k};
        $v = '' unless defined $v;
        printf("%-14s %s\n", $k, length $v ? $v : '(unset)');
    }
    return 0;
}

sub cmd_models {
    my (%a) = @_;
    my $p = OldAgent::Provider->new(config => $a{config});
    my ($models, $err) = $p->list_models;
    if ($err) { print STDERR "oldagent: $err\n"; return 1 }
    print($_ . "\n") for @$models;
    return 0;
}

sub cmd_tools {
    my (%a) = @_;
    my $t = OldAgent::Tools->new(root => $a{config}->get('root'));
    print $t->spec();
    print "\nworking root: " . ($a{config}->get('root') || '(no restriction)') . "\n";
    print "bash approval: " . $a{config}->get('approve') . "\n";
    return 0;
}

sub cmd_help { print _usage(); return 0 }
sub cmd_version { print "oldagent " . OldAgent::version() . " (perl $])\n"; return 0 }

sub cmd_desktop {
    my (%a) = @_;
    my $cfg = $a{config};
    eval {
        require OldAgent::Desktop;
        my $app = OldAgent::Desktop->new(config => $cfg);
        $app->main_loop();
    };
    if ($@) {
        print STDERR "oldagent: desktop error: $@\n";
        return 1;
    }
    return 0;
}

# ---------------------------------------------------------------- repl ----

sub repl {
    my (%a) = @_;
    my $agent  = $a{agent};
    my $cfg    = $a{config};
    # Pick the best line editor:
    #  - the real C readline (Term::ReadLine::Gnu / ::EditLine) if installed
    #  - our own wrapping editor (OldAgent::Term) on a tty
    #  - plain stdin when piped
    # Note: the Term::ReadLine *stub* backend reads /dev/tty, so it is
    # useless for piped input; skip it on purpose.
    my $term;
    my $edit = 'plain stdin (no line editing here)';
    my $cimpl = '';
    eval { require Term::ReadLine; $cimpl = $Term::ReadLine::IMPLEMENTATION || '' };
    if ($cimpl eq 'Gnu' || $cimpl eq 'EditLine') {
        $term = eval { Term::ReadLine->new('oldagent') };
        eval { $term->History(200); 1 } if $term;
        $edit = "readline ($cimpl): history, editing, wrap";
    } elsif (-t STDIN && open(my $probe, '<', '/dev/tty')) {
        close $probe;
        require OldAgent::Term;
        my $own = OldAgent::Term->new();
        if ($own) {
            $term = $own;
            $edit = 'built-in editor: up/down = history, arrows/edit keys, wrap';
        }
    }

    if (!$a{quiet_intro}) {
        print "oldagent " . OldAgent::version() . " - perl $], " . OldAgent::Util::uname() . "\n";
        printf "%s / %s / %s\n",
            $cfg->get('provider'), $cfg->get('base_url'), $cfg->get('model');
        printf "tools %s, bash approval %s. %s. type /help for commands, /quit to leave.\n",
            $cfg->get('tools') ? 'on' : 'off', $cfg->get('approve'), $edit;
    }

    while (1) {
        my $line = _read_line($term, 'oa> ');
        last unless defined $line;
        $line =~ s/\s+$//;
        next unless length $line;

        if ($line =~ m{^/([\w-]+)\s*(.*)$}) {
            my ($c, $rest) = ($1, $2);
            my $r = repl_command($c, $rest, agent => $agent, config => $cfg, term => $term);
            last if $r && $r eq 'quit';
            next;
        }

        # backslash continues a line, handy for pasting shell snippets
        while ($line =~ /\\\s*$/) {
            $line =~ s/\\\s*$//;
            my $more = _read_line($term, '  ... ');
            last unless defined $more;
            $line .= "\n" . $more;
        }

        my ($reply, $err) = $agent->ask($line);
        if ($err) {
            print "[oldagent] $err\n";
            $agent->undo;
        }
    }
    print "\n";
    return 0;
}

sub _read_line {
    my ($term, $prompt) = @_;
    if ($term) {
        my $l = $term->readline($prompt);
        return $l;
    }
    print($prompt);
    my $l = <STDIN>;
    return $l;
}

sub repl_command {
    my ($c, $rest, %a) = @_;
    my $agent = $a{agent};
    my $cfg   = $a{config};
    my @r     = split(/\s+/, $rest);

    if ($c eq 'quit' || $c eq 'exit' || $c eq 'q') { return 'quit' }
    if ($c eq 'help' || $c eq '?') { print _repl_help(); return }
    if ($c eq 'clear')             { $agent->reset; print "(history cleared)\n"; return }
    if ($c eq 'undo')              { my $n = $agent->undo; print "(dropped $n message(s))\n"; return }
    if ($c eq 'history') {
        my $i = 0;
        for my $m (@{ $agent->history }) {
            $i++;
            printf "%3d %-9s %s\n", $i, $m->{role},
                OldAgent::Util::clip(OldAgent::Util::one_line($m->{content}), 90);
        }
        print "(empty)\n" unless $i;
        return;
    }
    if ($c eq 'model') {
        if (@r) {
            $cfg->set(model => $rest);
            print "model = $rest\n";
            _remember($cfg, 'model');
        }
        else    { print "model = " . $cfg->get('model') . "\n" }
        return;
    }
    if ($c eq 'provider' || $c eq 'base-url' || $c eq 'url') {
        if ($c ne 'provider') {
            if (@r) {
                $cfg->set(base_url => $r[0]);
                print "base_url = $r[0]\n";
                _remember($cfg, 'base_url');
            }
            else   { print "base_url = " . $cfg->get('base_url') . "\n" }
            return;
        }
        if (@r) {
            my $arg = $r[0];
            if ($arg =~ /^(openai(-compat)?|ollama|anthropic|exec|echo)$/) {
                $cfg->set(provider => $arg);
                print "provider = $arg (base_url = " . $cfg->get('base_url') . ")\n";
                _remember($cfg, 'provider', 'base_url');
            } elsif (_looks_like_url($arg)) {
                my $u = $arg;
                $u = "http://$u" unless $u =~ m{^https?://};
                my $p = _infer_provider($u);
                $cfg->set(base_url => $u);
                $cfg->set(provider => $p) if $p ne $cfg->get('provider');
                print "provider = " . $cfg->get('provider')
                    . ", base_url = $u\n";
                _remember($cfg, 'provider', 'base_url', 'api_key', 'key_env');
            } else {
                print "not a known provider (openai, openai-compat, ollama, anthropic, exec, echo)\n";
                print "  and not a url. try:  /provider http://host:port/v1\n";
            }
        } else {
            _provider_wizard($a{term}, $cfg);
        }
        return;
    }
    if ($c eq 'turns') {
        if (@r && $r[0] =~ /^\d+$/) {
            $cfg->set(max_turns => $r[0]);
            print "max_turns = $r[0]\n";
            _remember($cfg, 'max_turns');
        }
        else { print "max_turns = " . $cfg->get('max_turns') . "\n" }
        return;
    }
    if ($c eq 'yes') { $cfg->set(approve => 'auto'); print "bash commands will run without asking\n"; _remember($cfg, 'approve'); return }
    if ($c eq 'no')  { $cfg->set(approve => 'ask');  print "bash commands will ask first\n"; _remember($cfg, 'approve'); return }
    if ($c eq 'tools') {
        if (@r && ($r[0] eq 'on' || $r[0] eq 'off')) {
            $cfg->set(tools => $r[0] eq 'on' ? 1 : 0);
            $agent->{tools_on} = $r[0] eq 'on' ? 1 : 0;
            print "tools " . $r[0] . "\n";
            _remember($cfg, 'tools');
        } else {
            print $agent->tools->spec();
        }
        return;
    }
    if ($c eq 'system') { $cfg->set(system_extra => $rest); print "(extra instructions set)\n"; _remember($cfg, 'system_extra'); return }
    if ($c eq 'cd') {
        my $d = @r ? $r[0] : OldAgent::Util::home_dir_guess();
        if (chdir($d)) { print "cwd = " . OldAgent::Util::cwd() . "\n" }
        else { print "cannot cd $d: $!\n" }
        return;
    }
    if ($c eq 'sh' || $c eq '!') {
        my $r = OldAgent::Util::run_cmd(cmd => $rest, timeout => 60);
        print $r->{out};
        print "[exit $r->{exit}]\n" if $r->{exit} != 0;
        return;
    }
    if ($c eq 'save') {
        my $f = @r ? $r[0] : 'oldagent-session.json';
        my $err = OldAgent::Util::spew($f, OldAgent::JSON::encode($agent->history) . "\n");
        print($err ? "$err\n" : "saved " . scalar(@{ $agent->history }) . " messages to $f\n");
        return;
    }
    if ($c eq 'load') {
        my $f = @r ? $r[0] : 'oldagent-session.json';
        my ($data, $err) = OldAgent::Util::slurp($f);
        if ($err) { print "$err\n"; return }
        my ($h, $derr) = OldAgent::JSON::decode($data);
        if ($derr || ref($h) ne 'ARRAY') { print "not an oldagent session file: $derr\n"; return }
        $agent->reset;
        push @{ $agent->history }, @$h;
        print "loaded " . scalar(@$h) . " messages\n";
        return;
    }
    if ($c eq 'version' || $c eq 'v') {
        my @files = $cfg->files;
        print "oldagent " . OldAgent::version() . "\n";
        print "config: " . (@files ? join(", ", @files) : "(defaults + environment)") . "\n";
        print "config file (for /model, /provider, ...): "
            . (OldAgent::Config::user_config_path() || '(none)') . "\n";
        return;
    }
    if ($c eq 'doctor') {
        my ($lines, $ok) = OldAgent::Doctor::report(config => $cfg, ping => 1);
        print(join("\n", @$lines) . "\n");
        return;
    }
    if ($c eq 'config') { cmd_config(config => $cfg, argv => [@r]); return }
    if ($c eq 'paste') {
        print "end with a single dot on a line\n";
        my @b;
        while (defined(my $l = <STDIN>)) {
            $l =~ s/\n$//;
            last if $l eq '.';
            push @b, $l;
        }
        my ($reply, $err) = $agent->ask(join("\n", @b));
        print "[oldagent] $err\n" if $err;
        return;
    }
    print "unknown command /$c - try /help\n";
    return;
}

# --------------------------------------------------------------- helpers --

# /provider wizard: protocol -> base url -> key
my @PROTOCOLS = (
    # key,             blurb,                                          default url
    ['openai',        'OpenAI, /v1/chat/completions (key)',            'https://api.openai.com/v1'],
    ['openai-compat', 'any OpenAI-compatible server, /v1',             ''],
    ['ollama',        'local Ollama, OpenAI dialect on /v1',           'http://127.0.0.1:11434/v1'],
    ['anthropic',     'Anthropic, /v1/messages (key)',                 'https://api.anthropic.com'],
    ['exec',          'pipe the conversation to a local command',      ''],
    ['echo',          'echo the prompt back; no network needed',       ''],
);

sub _key_state {
    my ($cfg) = @_;
    if (length $cfg->get('api_key')) {
        return $cfg->get('key_env')
            ? "env " . $cfg->get('key_env')
            : '(set)';
    }
    return '(none)';
}

sub _provider_summary {
    my ($cfg, $extra) = @_;
    my $s = "provider = " . $cfg->get('provider')
          . ", base_url = " . ($cfg->get('base_url') || '(none)')
          . ", key = " . _key_state($cfg);
    $s .= " $extra" if $extra;
    $s .= "\n  (no key yet: type it at the api key step, or export OPENAI_API_KEY)"
        if $cfg->get('provider') =~ /^openai/ && !length $cfg->get('api_key');
    return $s . "\n";
}

sub _remember {
    my ($cfg, @keys) = @_;
    my $p = $cfg->remember(@keys);
    print $p ? "(remembered in $p)\n" : "(could not remember setting)\n";
}

sub _provider_wizard {
    my ($term, $cfg) = @_;
    my $cur = $cfg->get('provider');

    print "\n(1) protocol - number, name, or a base url (current: $cur)\n";
    my $n = 0;
    for my $p (@PROTOCOLS) {
        $n++;
        printf "  %d  %-14s %s%s\n", $n, $p->[0], $p->[1],
            ($p->[0] eq $cur ? '  <- current' : '');
    }
    my $ans = _read_line($term, 'protocol> ');
    return unless defined $ans;
    $ans =~ s/\s+$//;

    my $proto;
    if ($ans =~ /^\d+$/ && $ans >= 1 && $ans <= @PROTOCOLS) {
        $proto = $PROTOCOLS[$ans - 1][0];
    } elsif ($ans =~ /^(openai(-compat)?|ollama|anthropic|exec|echo)$/) {
        $proto = lc($ans);
    } elsif (length $ans && _looks_like_url($ans)) {
        my $u = $ans;
        $u = "http://$u" unless $u =~ m{^https?://};
        my $p = _infer_provider($u);
        $cfg->set(base_url => $u);
        $cfg->set(provider => $p) if $p ne $cfg->get('provider');
        print _provider_summary($cfg, '(from url)');
        _remember($cfg, 'provider', 'base_url');
        return;
    } elsif (length $ans) {
        print "no such protocol: $ans\n";
        return;
    } else {
        $proto = $cur;
    }

    my ($meta) = grep { $_->[0] eq $proto } @PROTOCOLS;
    my ($blurb, $durl) = ($meta->[1], $meta->[2]);
    my $need_url = $proto ne 'exec' && $proto ne 'echo';
    my $need_key = $proto ne 'exec' && $proto ne 'echo';

    # (2) base url
    my $url = '';
    if ($need_url) {
        my $def = length $durl ? $durl : $cfg->get('base_url');
        print "(2) base url - $blurb\n    [ $def ]  (enter = use that)\n";
        my $a2 = _read_line($term, 'base url> ');
        return unless defined $a2;
        $a2 =~ s/\s+$//;
        $url = length $a2 ? $a2 : $def;
        $url =~ s{/+$}{""};
    } else {
        print "(2) base url - not needed for $proto\n";
    }

    # (3) api key
    if ($need_key) {
        print "(3) api key - current: " . _key_state($cfg)
            . "\n    enter = keep, \"none\" = no key\n";
        my $a3 = _read_line($term, 'api key> ');
        return unless defined $a3;
        $a3 =~ s/\s+$//;
        if (lc($a3) eq 'none') {
            $cfg->set(api_key => '');
            $cfg->set(key_env => '');
        } elsif (length $a3) {
            $cfg->set(api_key => $a3);
            $cfg->set(key_env => '');
        }
    } else {
        print "(3) api key - not needed for $proto\n";
    }

    $cfg->set(provider => $proto);
    $cfg->set(base_url => $url) if $need_url;
    print _provider_summary($cfg);
    _remember($cfg, 'provider', 'base_url', 'api_key', 'key_env');
    return;
}

sub _looks_like_url {
    my ($u) = @_;
    return 1 if $u =~ m{^https?://};
    return 1 if $u =~ m{^[\w.-]+:\d+(?:/|$)};        # host:port[/path]
    return 1 if $u =~ m{^[\w.-]*\.[\w.-]+(?:/|$)} && $u !~ m{^gpt-} && $u !~ m{^claude-};
    return 0;
}

sub _infer_provider {
    my ($u) = @_;
    return 'anthropic' if $u =~ m{anthropic};
    return 'ollama'    if $u =~ m{ollama|11434};
    return 'openai-compat';
}

sub _attach_files {
    my ($files, $text) = @_;
    return $text unless $files && @$files;
    my $extra = '';
    for my $f (@$files) {
        my ($data, $err) = OldAgent::Util::slurp($f);
        if ($err) { $extra .= "\n[could not read $f: $err]\n"; next }
        $extra .= "\n--- $f ---\n" . OldAgent::Util::clip($data, 8000) . "\n";
    }
    return $text . $extra;
}

sub _read_stdin {
    return '' if -t STDIN;
    my $in = do { local $/; <STDIN> };
    return defined $in ? $in : '';
}

sub _usage {
    return <<'EOT';
oldagent - a tiny agent for old perl and older machines

usage: oa [flags] [command] [args]

commands
  (none)          interactive session, tools on
  ask <text>      one question, no tools (also: oa -p "text")
  do <text>       one task, tools on, prints the summary
  doctor          what does this machine have? (--ping to test the model)
  models          list models the endpoint knows
  tools           show the tool list the model sees
  config [init]   show settings / write an oldagentrc
  desktop         Tk front end (needs the Tk perl module)
  help, version

flags
  --provider NAME   openai | ollama | anthropic | exec | echo
  --base-url URL    default https://api.openai.com/v1
  --model NAME      model id
  --key KEY         api key (or OPENAI_API_KEY etc; none = local endpoint)
  --exec CMD        provider=exec: pipe the transcript to CMD
  --http NAME       curl | wget | httptiny | lwp | socket | auto
  --root DIR        refuse file writes outside DIR
  --turns N         max tool round trips per task (default 12)
  --timeout N       seconds per model call (default 120)
  -y, --yes         run bash commands without asking
  --no-tools        disable tools entirely
  -F, --file FILE   attach a file to the prompt (repeatable)
  --cd DIR          start in DIR
  --config FILE     use this config file
  --no-config       ignore config files
  -q, --quiet       only the answer

examples
  oa doctor
  oa --base-url http://127.0.0.1:11434/v1 --model llama3.1
  oa do "find every TODO in src/ and write them to todos.txt"
  oa --provider exec --exec "llama-cli -m model.gguf" "summarise readme.md"
EOT
}

sub _repl_help {
    return <<'EOT';
  /help            this
  /quit            leave (also /q, /exit)
  /clear           forget the conversation
  /undo            drop the last exchange
  /history         what is in context
  /model [NAME]    show or set the model
  /provider        wizard: protocol, base url, key - or /provider <name|url>
  /base-url [URL]  show or set the endpoint url
  /turns [N]       how many tool round trips per message
  /tools [on|off]  show tools, or switch them
  /yes  /no        run bash without asking / ask first
  /system TEXT     add standing instructions
  /cd [DIR]        move the working directory
  /sh CMD          run a command now, outside the conversation
  !CMD             same
  /paste           multi-line message, end with a single dot
  \ at line end    continue on the next line
  /save [FILE]     write the transcript to a file
  /load [FILE]     read one back
  /doctor          environment report
  /version         which oldagent this is, and which config files it read
EOT
}

1;
