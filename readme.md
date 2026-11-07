<p align="center">
<img width="640" height="360" alt="oa" src="https://github.com/user-attachments/assets/9afd0382-65dd-46ec-b1a8-ca849b84a92b" />

</p>

A tiny agent for machines that time forgot to do agentic sysadmin tasks on older boxes.

`oldagent` is a helper like hermes or any of the other terminal agents: it
reads files, writes files, runs shell commands, and talks to a model with or
without an API key. The difference is that it is **pure Perl with zero
dependencies**, so it runs on the perl that is already sitting on an old
install - think 2005, think Ubuntu 12.04, think a Solaris box nobody will
patch, think a build container with `perl 5.6.1` and nothing else.

The machine is old. The model is not: point it at whatever you run today -
ollama on a box down the hall, or a hosted model through `oa-proxy` when
the old box cannot speak TLS. Nothing here is tuned for weak models.

```
oa doctor
oa
oa do "find every TODO in src/ and write them to todos.txt"
```

Proof? Here you go, HP-UX on 32-bit PA-RISC
<img width="1280" height="1024" alt="hpux" src="https://github.com/user-attachments/assets/d2942ed2-625c-4e3b-9108-7521d82531bc" />

Ok What about Solaris with OPEN LOOK?
<img width="1024" height="768" alt="solaris8" src="https://github.com/user-attachments/assets/93e3a61d-78c4-4a8b-a894-18968f06ffeb" />

Here's the gui, `oa desktop`
<img width="1280" height="1024" alt="desktop" src="https://github.com/user-attachments/assets/18e64aec-9e40-4edd-9324-0e9c9a436e72" />

"Ok" you say, "what about something older". Alright, here you go:
<img alt="next" src="https://github.com/user-attachments/assets/b523bf02-1815-490c-8d83-179795a9bc4a" />

## requirements

* perl 5.006 (2000) or newer. Nothing from CPAN. (perl 5.001? see `oa1`
  below: one file, fewer tools, same protocol.)
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
proxy    = 10.0.0.126:8470         # oa-proxy on a modern box, or --proxy
```

## how it drives the model

The protocol is text, not an API feature: a tool call is a fenced block in
the reply, so it works the same over ollama's native endpoint, anything
OpenAI-shaped, Anthropic, or a command the transcript is piped into, and
the old box needs no client library to speak it. A modern model follows it
without being told twice (native `tool_calls` are translated into the same
form when an endpoint returns them). The agent asks for a tool with a
fenced block, execution stops, and results come back in the next message:

    ```tool
    {"tool":"bash","args":{"cmd":"ls -l"}}
    ```

    ```result
    {"tool":"bash","ok":true,"output":"total 4\ndrwxr-xr-x 2 chris chris 4096 README/"}
    ```

Tools: `read`, `write`, `edit`, `list`, `find`, `bash`, `done`. The parser is
forgiving (` ```json `, `name`/`arguments`, flat args, unterminated fences,
trailing commas) because even good models get the shape slightly wrong
now and then. `bash` asks a human first
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
oa-proxy           the companion bridge for legacy boxes (see below)
```

In the REPL: `/help`, `/model`, `/provider <name|url>`, `/base-url`, `/tools`,
`/yes`, `/undo`, `/history`, `/save`, `/load`, `/cd`, `/sh cmd`, `/paste`,
`/fmt on|off`, `/editor`, `/version`, `/doctor`, `/proxy <host:port|off>`.

`/provider` takes either a provider name (`openai`, `ollama`, `anthropic`,
`exec`, `echo`) or a base URL — `https://9ol.es/11434` — in which case the
provider is inferred (a `/v1` suffix means OpenAI-compatible, an `ollama`
host means Ollama). With no argument it becomes a small wizard: choose the
protocol from a numbered list, type the base URL (Enter keeps the
sensible default), and enter an API key (blank keeps the current one,
`none` clears it).

Settings you change in the session are remembered: `/model`, `/provider`,
`/base-url`, `/turns`, `/system`, `/tools`, `/yes`/`/no` write the new
values into your config file (`~/.oldagentrc`, or `$OLDAGENT_CONFIG` if
you set one; `/version` tells you which file is in play), so the next
session starts where this one ended. You should have to tell it once.

`oa desktop` is a Tk front end on the same loop, rendered with the same
markdown-lite formatter. Tk is not core perl, so it stays off the critical
path: `oa` works without it, and it only loads if `Tk` is present.

## markdown, in a terminal and a window

Replies are rendered by a small markdown-lite pass (bold, italic,
underscore emphasis, inline code, strikeout, links, images, block quotes,
headings, lists, fenced code). In a terminal it becomes ANSI colour and
weight, off the moment the output is piped. The same token stream drives
the Tk window, where it becomes font weight and colour instead of escapes.
The inline parser is a left-to-right state machine modelled on streamdown /
CommonMark, so `**bold**`, `*slant*`, `_underscore_`, `` `code` ``,
`***both***` and `~~gone~~` all come out right, and `snake_case` does not.

## repository

```
oa                     entry point
oa-proxy               the companion bridge (modern perl, no old-Perl rules)
oa1                    the one-file edition for perl 5.001 (OPENSTEP, SunOS 4)
lib/OldAgent.pm        version, config discovery
lib/OldAgent/CLI.pm    flags and the REPL
lib/OldAgent/Agent.pm  the loop, the system prompt, approvals
lib/OldAgent/Tools.pm  read/write/edit/list/find/fetch/bash
lib/OldAgent/Protocol.pm  tool-call parsing, result blocks
lib/OldAgent/Provider.pm  openai / ollama / anthropic / exec / echo
lib/OldAgent/HTTP.pm   curl, wget, HTTP::Tiny, LWP, raw socket (+ proxy relay)
lib/OldAgent/Proxy.pm  client for oa-proxy (used only when /proxy is set)
lib/OldAgent/JSON.pm   JSON, because JSON.pm is not in old perl
lib/OldAgent/Config.pm config layers
lib/OldAgent/Textfmt.pm  markdown-lite: a token stream for both ANSI and Tk
lib/OldAgent/Term.pm   a small line editor: history, arrows, wrapping
lib/OldAgent/Desktop.pm  the optional Tk window
lib/OldAgent/Doctor.pm environment report and self test
util/compat-lint.pl    keeps the code 5.006-safe
util/desk-trace.pl     drives the desktop through a conversation under xvfb
                       and reports rebuilds, self-resizing, screen/history drift
t/                     349 tests, no network needed (t/97 is oa1 against a
                       fake ollama on a local socket)
```

## oa1: one file, for perl 5.001

`oa1` is oldagent for a perl older than the one `oa` is written for: a
NeXT running OPENSTEP 4.2 ships perl 5.001 (1995), and 5.001 has no `our`,
no `foreach my`, no `qr//`, no `$f->()`, no three-argument `open`, no
`POSIX`, no `IO::*`, no `File::Spec`, and `use strict` does not know about
`$a` and `$b` outside package main. Porting the tree down to that dialect
would wreck it for everything newer, so `oa1` is a separate single file
(about 1100 lines) written in perl 5.000: references, `my`, `=>`, closures
called as `&$f()`, named signal handlers, bareword filehandles.

it speaks the same tool protocol as `oa` (```tool blocks in, ```result
blocks back, the same system prompt and rules), reads the same
`~/.oldagentrc`, and talks to ollama's native `/api/chat` (streaming, token
by token) or an OpenAI-compatible `/v1/chat/completions` over a raw socket.
http only: a machine this old has no TLS anyway, so point it at a local
model or at oa-proxy. tools: read, write, edit, list, bash (with the
same ask / auto / off approval on the terminal), done.

```
perl oa1 --base-url http://10.0.0.1:11434 --model qwen3.8 models
perl oa1 ask "hello, in one sentence what are you?"
perl oa1 do "what kind of computer do I have? one command is enough"
perl oa1                 # a session: /model, /base, /approve, /help, /quit
```

you do not have to know which one to run: `oa` checks `$]` before it
parses anything else and, on a perl older than 5.006, execs `oa1` next to
it with a one-line note (`OA_MINIMAL=1` forces that on any perl). `oa1
doctor` shows the settings, the shell, uname or hostinfo, the tty, and
whether the endpoint answers; `--debug` prints the system prompt, raw
replies, calls and results on stderr; `--ascii` (the default unless LANG
says utf-8) folds the model's em dashes and curly quotes to ascii, since
a 1990s terminal shows an em dash as `b`.

on a 486 with 64 MB under OPENSTEP 4.2 a chat answer streams in about
five seconds with no measurable CPU. "tell me a bit about this machine"
made the model run four read-only probes (hostinfo/vm_stat, `ls /`,
`/NextApps`, the home directory), read the readme, and conclude "a vintage
NeXTSTEP box on a 486, running a minimal Perl agent" - a couple of
minutes, almost all of it the model's own time. getting the tree there:
the box has ftp, so `curl -T oldagent.tar ftp://user:pass@box/` and
`gnutar xf`. `t/97-oa1.t` runs oa1 against a fake ollama on a local socket,
lints it for anything newer than 5.001, and checks the handoff. there is
no desktop for it: no Tk, no X, and no plan for one.

## oa-proxy: a bridge for machines that stopped in 2000

A box from 2000 has no TLS and no `curl` that speaks HTTPS. `oa-proxy` is a
small service you run on a *modern* machine (macOS/Linux, modern perl). The
legacy box points at it with `/proxy host:port` and everything that needs the
internet goes over plain HTTP to the proxy, which does the modern bit for it:

```
legacy box (perl 5.006, no TLS)  --plain http-->  oa-proxy  --https-->  the web
```

Endpoints, all `POST` with a JSON body:

| path      | does                                                        |
|-----------|-------------------------------------------------------------|
| `/status` | what the proxy can do (fetch, lightpanda, mcp servers)      |
| `/fetch`  | get a url as markdown (via lightpanda) or raw text          |
| `/req`    | relay any request (method/headers/body) over HTTPS, raw back|
| `/mcp`    | list or call a tool on a stdio MCP server (`mcp.json`)      |
| `/shot`   | take a base64 image and save it to a file                   |

On the legacy box, `oa-proxy` is invisible: `HTTP` relays any `https://` URL
through it when `proxy` is set, the `fetch` tool uses it for `fetch` markdown,
and `/proxy host:port` (re)configures and probes it. Nothing loads until you
set a proxy, so the dependency-free critical path is untouched. MCP servers
are declared in a `mcp.json` (`{"mcpServers":{name:{command,args,description}}}`)
and reachable as `fetch`-style calls the model can make.

Run it:

```
oa-proxy --port 8470 --mcp ~/.oldagent/mcp.json \
         --lightpanda ~/.local/bin/lightpanda
```

It listens on every interface (0.0.0.0) and says how to reach it as it
starts: the `/proxy host:port` line to type in `oa` on the old box, one per
address this machine has, and what it can do (fetch, lightpanda, which mcp
servers loaded, where screenshots go). Every request is then logged as one
line: who asked, what for, how it went, how long it took. `--verbose` adds
detail; `--quiet` silences it; `--host 127.0.0.1` keeps it local.

On the old box, `oa --proxy host:port` does what `/proxy host:port` does
in the session (`--proxy off` ignores one the rc file set).

## changelog

0.1.11
- nothing shown on the terminal is cut any more. the `[tool]` line used to
  clip each argument at 60 chars and the line at 160 and add "...", which
  on an 80-column terminal wrapped onto a line of its own. the command is
  shown bare and whole, a multi-line argument (a `write`) as an indented
  block; `/history` prints whole messages; oa1 prints a whole result
  instead of 20 lines and a count.
- the model call has no timeout by default (it was 120 s). a modern model
  thinking for three minutes is not a hung box, and the stream shows it is
  alive. `--timeout N` or `timeout = N` in the rc sets a limit; 0 is none.
  every http backend honours 0: curl and wget get no `--max-time` / `-T`,
  the raw socket has no deadline. same in oa1.
- readme: the premise is an old machine and a modern model; "old models
  do not have function calling" is gone.

0.1.10
- `oa-proxy` says how to connect to it when it starts (the `/proxy
  host:port` to type on the old box, one per address this machine has, and
  what it can do) and logs every request as one line (client, endpoint,
  url or mcp tool, ok or the error, size, seconds). it used to say nothing
  at all. it binds 0.0.0.0 by default now (it was 127.0.0.1, which no old
  box could reach); `--host 127.0.0.1` keeps it local, `--quiet` silences
  it. `/status` now reports lightpanda as present when it is on PATH, not
  only when given as a full path.
- `oa --proxy HOST:PORT` sets the proxy from the command line (`off`
  clears one from the rc file). `oa1` accepts and ignores it, since the
  handoff passes every flag through.

0.1.9
- ollama native (`/api/chat`): the system prompt was sent as a top-level
  `system` field, which that endpoint ignores (it belongs to `/api/generate`),
  so a model behind a `/v1`-less base url never learned it had tools and
  answered like a chatbot ("I don't have access to external tools"). it
  goes as the first message with role `system` now, on the one-shot and the
  streaming path (t/43-ollama-payload.t). the openai-compatible path was
  always right, which is why the HP-UX box never showed it.
- the system prompt says that questions about the machine - what it is,
  what is installed, what is wrong - are answered by running a command,
  not from memory.
- `oa` hands over to `oa1` on a perl older than 5.006 (the check runs
  before anything else in the file is parsed); `OA_MINIMAL=1` forces it.
- `oa1`: oldagent in one file for perl 5.001 (OPENSTEP 4.2 on a 486 is
  the test box). same protocol, same rc, raw-socket http to ollama
  (streaming) or an OpenAI-compatible endpoint; read/write/edit/list/bash
  /done with terminal approval; `--debug` shows raw replies and calls.
  a reply that is nothing but one backticked command is taken as a bash
  proposal (small models do that) - it still goes through approval.
  `oa1 doctor`; `--ascii` folds utf-8 punctuation for 1990s terminals.
  t/97-oa1.t: a fake ollama on a local socket plus a dialect lint.

0.1.8
- a reply with no tool call ends the turn. the loop only nudges the model
  when it narrates a step instead of taking it ("Let me read the file
  first..."); a chat answer is an answer, not a failure to act. the system
  prompt no longer insists the model is not a chatbot.
- desktop: `done` blocks and `result` fences are protocol, not transcript;
  short one-line summaries no longer come out as `d [... clipped 0 chars
  ...] one summary=...`; the second message no longer hangs on "Thinking";
  a Stop button; bold, code and the other markdown tags actually render
  (the tag list reached Tk as one joined name before).
- desktop: tool calls are shown in full, results as a block of the first
  20 lines. a bash call asks for approval in the window
  (Allow / Always / Deny) instead of on the terminal the desktop was
  started from, where nobody was looking - and the event pipe is now
  actually non-blocking, so a waiting child no longer freezes the window.
  the child gets its message on stdin instead of argv (the api key was
  visible in `ps`).
- desktop: no more flashing or self-resizing. the transcript is drawn
  incrementally (one rebuild, at startup; the streamed reply grows in
  place) and the window keeps the size you gave it.
- desktop: plain text, no boxes - you in blue on the right, the agent in
  plain text with the markdown, tool lines small and grey. one text
  widget and tags, nothing measured: quick on a PA-RISC. (the widget
  bubbles tried in between never shipped.)
- desktop: `Commands > Show config` works (the captured-output handle
  lacked `printf`).
- a box without curl gets the one-shot reply without first trying to
  stream (and without the "uninitialized value" warning it used to print).
- an OpenAI-compatible `base_url` without `/v1` (ollama's
  `http://host:11434`) works: a 404 makes oa retry under `/v1` and stay
  there. the stream path used to turn that 404 into an empty reply.
- HP-UX 11i / perl 5.8.8: the suite is green; the desktop tests skip
  (instead of bailing the whole run) where there is no xvfb, and the tty
  approval test is opt-in (`OA_TTY_TEST=1`).

0.1.7
- `oa-proxy`: a companion bridge service (modern perl) for legacy boxes with no
  TLS/curl-for-HTTPS. Endpoints: `/status`, `/fetch` (markdown via lightpanda,
  or raw), `/req` (relay any request over HTTPS), `/mcp` (list/call tools on
  stdio MCP servers from a `mcp.json`), `/shot` (base64 image relay).
- `OldAgent::Proxy`: a 5.006-safe client for the bridge, loaded only when a
  proxy is configured. `HTTP` now relays any `https://` URL through it, so a
  2000s box can call a modern HTTPS provider.
- new `fetch` tool (`fetch url [markdown=1] [max_bytes=N]`): fetch a url, via
  the proxy for `https`, locally for `http`. Aliased `get`/`download`/`url`.
- `/proxy host:port` REPL command: set/clear/probe the bridge; persisted like
  the other settings. `/proxy off` to disconnect.
- provider tool-call robustness carried over; desktop transcript cleanup,
  streaming, and settings-reach-the-provider from the desktop.

0.1.6
- HP-UX 5.8.8 fixes: a stray `%` before a `%{...}` hash deref is a parse
  error on old perl (gone); `GetOptionsFromArray` (5.010+) is used only when
  present; a config-persistence test now uses a `$`-under-`/m`-safe pattern
  (old perl does not treat `$` as a line boundary under `/m`).
- error message for a bad HTTP status is now "request to <url> failed
  (http <n>)" so the reason is clear even when the underlying socket error
  text differs by platform.
- Ollama: streamed/NDJSON replies are joined correctly (so a non-empty last
  chunk is not lost), the `think` option is passed when `thinking` is set,
  and a `thinking` field is surfaced when `content` is empty.
- tool-call parsing now also recognises native model tool markup
  (`<|tool_call>call:tool{...}</tool_call|>`), OpenAI-style
  `{"function":..., "arguments":...}` and `{"name":..., "arguments":...}`, and
  a bare `{"command":"..."}` (treated as `bash`). `arguments` may be a JSON
  string.
- the system prompt no longer primeds the model to call itself a text-only
  assistant.

0.1.5
- the approval prompt no longer auto-denies while the line editor's raw mode
  is still in force (the terminal is put back to canonical mode before the
  read).
- a code span no longer leaves the rest of the reply coloured (a
  `grep {...} ? a : b` precedence trap).
- the cursor no longer jumps a line per keystroke when the prompt wraps.

## keeping it old

`util/compat-lint.pl` (run by `t/90-compat.t`) rejects `say`, `//`,
signatures, smartmatch, `List::Util`, `JSON`, `Time::HiRes`, and everything
else that a perl from 2000 has never seen. If you want to add a dependency,
the answer is no; write forty lines instead.
