package OldAgent::Config;
# key = value config with three layers: defaults < files < environment < flags.

use strict;
use warnings;

use OldAgent ();
use OldAgent::Util ();

my %DEFAULT = (
    provider     => 'openai',
    base_url     => '',
    model        => 'gpt-4o-mini',
    api_key      => '',
    key_env      => '',
    temperature  => '',
    max_tokens   => '1024',
    timeout      => '120',
    http         => 'auto',
    tools        => '1',
    approve      => 'ask',       # ask | auto | off
    max_turns    => '12',
    max_output   => '4000',
    root         => '',
    history_chars => '48000',
    system_extra => '',
    exec_cmd     => '',
    verbose      => '0',
);

my @KEY_ENVS = ('OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'OPENROUTER_API_KEY',
                'GROQ_API_KEY', 'LLAMA_API_KEY');

sub defaults { my %d = %DEFAULT; return \%d }

sub new {
    my ($class) = @_;
    my $self = { v => { %DEFAULT }, set => {}, files => [] };
    return bless $self, $class;
}

sub parse_line {
    my ($line) = @_;
    $line =~ s/^\s+//;
    return (undef, undef) if $line =~ /^#/;
    return (undef, undef) unless $line =~ /^([A-Za-z_][A-Za-z0-9_.-]*)\s*=\s*(.*)$/;
    my ($k, $v) = (lc $1, $2);
    $v =~ s/\s+$//;
    $v =~ s/^"(.*)"$/$1/;
    $v =~ s/^'(.*)'$/$1/;
    return ($k, $v);
}

sub load_file {
    my ($self, $path) = @_;
    my ($data, $err) = OldAgent::Util::slurp($path);
    return undef if $err;
    push @{ $self->{files} }, $path;
    for my $line (split(/\n/, $data)) {
        my ($k, $v) = parse_line($line);
        next unless defined $k;
        $self->{v}{$k} = $v;
        $self->{set}{$k} = 1;
    }
    return 1;
}

sub load_env {
    my ($self) = @_;
    for my $k (keys %DEFAULT) {
        my $env = 'OA_' . uc($k);
        if (defined $ENV{$env} && length $ENV{$env}) {
            $self->{v}{$k} = $ENV{$env};
            $self->{set}{$k} = 1;
        }
    }
    # conventional vendor variables
    if (!length $self->{v}{api_key}) {
        for my $e (@KEY_ENVS) {
            if (defined $ENV{$e} && length $ENV{$e}) {
                $self->{v}{api_key} = $ENV{$e};
                $self->{v}{key_env} = $e;
                $self->{set}{api_key} = 1;
                last;
            }
        }
    }
    if (!$self->{set}{base_url}) {
        if (defined $ENV{OPENAI_BASE_URL} && length $ENV{OPENAI_BASE_URL}) {
            $self->{v}{base_url} = $ENV{OPENAI_BASE_URL};
            $self->{set}{base_url} = 1;
        } elsif (defined $ENV{OLLAMA_HOST} && length $ENV{OLLAMA_HOST}) {
            my $h = $ENV{OLLAMA_HOST};
            $h = "http://$h" unless $h =~ m{^https?://};
            $self->{v}{base_url} = "$h/v1";
            $self->{set}{base_url} = 1;
            if (!$self->{set}{provider}) {
                $self->{v}{provider} = 'ollama';
                $self->{set}{provider} = 1;
            }
        }
    }
    return $self;
}

sub load {
    my ($class, %a) = @_;
    my $self = $class->new;
    if (!$a{no_files}) {
        for my $f (OldAgent::config_candidates()) {
            $self->load_file($f) if $f && -f $f;
        }
    }
    $self->load_env;
    if ($a{overrides}) {
        for my $k (keys %{ $a{overrides} }) {
            my $v = $a{overrides}{$k};
            next unless defined $v;
            $self->{v}{$k} = $v;
            $self->{set}{$k} = 1;
        }
    }
    $self->finalize;
    return $self;
}

sub finalize {
    my ($self) = @_;
    my $v = $self->{v};
    $v->{provider} = lc(OldAgent::Util::strip($v->{provider}));
    $v->{approve}  = lc(OldAgent::Util::strip($v->{approve}));
    $v->{http}     = lc(OldAgent::Util::strip($v->{http}));
    if ($v->{approve} eq 'yes' || $v->{approve} eq 'always') { $v->{approve} = 'auto' }
    if ($v->{approve} eq 'no' || $v->{approve} eq 'never')   { $v->{approve} = 'ask' }

    # provider-derived defaults, but never over an explicit base_url/model
    if (!$self->{set}{base_url}) {
        if ($v->{provider} eq 'ollama') {
            $v->{base_url} = 'http://127.0.0.1:11434';
        } elsif ($v->{provider} eq 'anthropic') {
            $v->{base_url} = 'https://api.anthropic.com';
        } else {
            $v->{base_url} = 'https://api.openai.com/v1';
        }
    }
    if (!$self->{set}{model} && $v->{provider} eq 'anthropic') {
        $v->{model} = 'claude-3-haiku-20240307';
    }
    if ($v->{provider} eq 'exec' && !length $v->{exec_cmd}) {
        $v->{exec_cmd} = $ENV{OA_EXEC} || 'cat';
    }
    $v->{base_url} =~ s{/+$}{};
    if ($v->{provider} eq 'ollama' && $v->{base_url} =~ m{/v1$}) {
        # /v1 is ollama's OpenAI-compatible surface; remember which dialect to speak
        $v->{openai_compat} = 1;
    }
    if ($v->{provider} eq 'ollama' && !$v->{openai_compat}) {
        $v->{base_url} =~ s{/v1$}{};
    }
    for my $n ('timeout', 'max_turns', 'max_output', 'history_chars') {
        $v->{$n} = 0 + $v->{$n} if defined $v->{$n} && length $v->{$n};
    }
    return $self;
}

sub get { my ($self, $k, $d) = @_; return exists $self->{v}{$k} ? $self->{v}{$k} : $d }
sub set {
    my ($self, $k, $v) = @_;
    $self->{v}{$k} = $v;
    $self->{set}{$k} = 1;
    return $self;
}
sub all { my ($self) = @_; return { %{ $self->{v} } } }
sub files { return @{ $_[0]{files} } }

sub redacted {
    my ($self) = @_;
    my %h = %{ $self->{v} };
    $h{api_key} = $h{api_key} ? OldAgent::Util::redact($h{api_key}) : '(none)';
    return \%h;
}

sub write_file {
    my ($self, $path) = @_;
    my @order = sort keys %{ $self->{v} };
    my $text = "# oldagent config\n";
    for my $k (@order) {
        my $v = $self->{v}{$k};
        next unless defined $v && length $v;
        next if $k eq 'api_key';
        $text .= "$k = $v\n";
    }
    $text .= "# api_key = put-your-key-here\n";
    return OldAgent::Util::spew($path, $text);
}

1;
