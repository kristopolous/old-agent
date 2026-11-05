<p align="center">
<img width="640" height="360" alt="oa" src="https://github.com/user-attachments/assets/9afd0382-65dd-46ec-b1a8-ca849b84a92b" />

</p>

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

Proof? Here you go, HP-UX on 32-bit PA-RISC
<img width="1280" height="1024" alt="hpux" src="https://github.com/user-attachments/assets/d2942ed2-625c-4e3b-9108-7521d82531bc" />


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
t/                     281 tests, no network needed
```

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

## changelog

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
