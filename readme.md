# oldagent

A tiny agent for machines that time forgot.

`oldagent` is a helper like hermes or any of the other terminal agents: it
reads files, writes files, runs shell commands, and talks to a model with or
without an API key. The difference is that it is **pure Perl with zero
dependencies**, so it runs on the perl that is already sitting on an old
install - think 2005, think Ubuntu 12.04, think a Solaris box nobody will
patch, think a build container with `perl 5.6.1` and nothing else.

```
oa doctor
oa
oa do "find every TODO in src/ and write them to todos.txt"
```

## why perl, and not C

C would need libssl headers that a 2000-era box does not have, and building
them is a weekend you will never get back. Perl 5.6 shipped with the OS. For
TLS we do not link anything: we shell out to the `curl` or `wget` that is
already there, and fall back to a raw `IO::Socket::INET` client for plain
http (local proxies, ollama, a gateway on the LAN). Nothing here needs a
compiler, a CPAN mirror, or root.

## requirements

* perl 5.006 (2000) or newer. Nothing from CPAN.
* `sh` for the bash tool, `curl` or `wget` for https (one of them is
  basically always installed).
* Optional and used only if present: `HTTP::Tiny`, `LWP`, `IO::Socket::SSL`,
  `Term::ReadLine`.

`oa doctor` tells you what it found and proves the loop works without a
network.

## install

```
perl Makefile.PL && make test && make install    # or:
./oa doctor                                       # run it from the tree
```

## talking to a model

Provider is one of `openai`, `ollama`, `anthropic`, `exec`, `echo`.

```
# hosted, with a key
oa --model gpt-4o-mini ask "what is in this directory?"

# local ollama, no key
oa --base-url http://127.0.0.1:11434/v1 --model llama3.1

# anything OpenAI-shaped: vLLM, LM Studio, LocalAI, llama.cpp's server,
# OpenRouter, Groq, an nginx proxy on port 8080
oa --base-url http://192.168.1.9:8080/v1 --model qwen2.5

# no server at all: pipe the transcript to a command
oa --provider exec --exec "llama-cli -m model.gguf --simple-prompt" ask "hi"
```

Config comes from `./oldagentrc`, `~/.oldagentrc`, `OA_*` environment
variables, then flags (flags win). `oa config init` writes a starting file;
`oa config` shows what is in effect with the key redacted.

```
provider = openai
base_url = https://api.openai.com/v1
model    = gpt-4o-mini
api_key  = put-your-key-here      # or OPENAI_API_KEY, never commit this
approve  = ask                    # ask | auto
root     = /srv/build             # refuse writes outside this
http     = auto                   # curl | wget | httptiny | lwp | socket
```

## how it drives the model

Old models do not have function calling, so the protocol is text and every
model on earth can follow it. The agent asks for a tool with a fenced block,
execution stops, and results come back in the next message:

    ```tool
    {"tool":"bash","args":{"cmd":"ls -l"}}
    ```

    ```result
    {"tool":"bash","ok":true,"output":"total 4\ndrwxr-xr-x 2 chris chris 4096 README/"}
    ```

Tools: `read`, `write`, `edit`, `list`, `find`, `bash`, `done`. The parser is
forgiving (` ```json `, `name`/`arguments`, flat args, unterminated fences,
trailing commas) because models are children. `bash` asks a human first
unless you pass `-y`; with no tty it refuses.

## terminal interface

```
oa                 interactive session
oa ask "question"  one shot, no tools
oa do "task"       one shot, tools on
oa doctor          environment report (--ping to reach out to the model)
oa models          what the endpoint has
oa tools           what the model thinks it can do
oa config          settings
```

In the REPL: `/help`, `/model`, `/tools`, `/yes`, `/undo`, `/history`,
`/save`, `/load`, `/cd`, `/sh cmd`, `/paste`, `/doctor`.

`oa desktop` (a Tk front end on the same loop) is not built yet; Tk is not
core perl, so it stays off the critical path.

## repository

```
oa                     entry point
lib/OldAgent.pm        version, config discovery
lib/OldAgent/CLI.pm    flags and the REPL
lib/OldAgent/Agent.pm  the loop, the system prompt, approvals
lib/OldAgent/Tools.pm  read/write/edit/list/find/bash
lib/OldAgent/Protocol.pm  tool-call parsing, result blocks
lib/OldAgent/Provider.pm  openai / ollama / anthropic / exec / echo
lib/OldAgent/HTTP.pm   curl, wget, HTTP::Tiny, LWP, raw socket
lib/OldAgent/JSON.pm   JSON, because JSON.pm is not in old perl
lib/OldAgent/Config.pm config layers
lib/OldAgent/Doctor.pm environment report and self test
util/compat-lint.pl    keeps the code 5.006-safe
t/                     176 tests, no network needed
```

## keeping it old

`util/compat-lint.pl` (run by `t/90-compat.t`) rejects `say`, `//`,
signatures, smartmatch, `List::Util`, `JSON`, `Time::HiRes`, and everything
else that a perl from 2000 has never seen. If you want to add a dependency,
the answer is no; write forty lines instead.
