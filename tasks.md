# task sheet

working order: local desktop first, then HP-UX, then release.
snapshots: use `DISPLAY=:1` (Xnest 1024x768) via xdotool + util/snap.pl + tesseract.

## 1. desktop shows the reply (local) - REGRESSION FOUND
- [x] repro: click entry, send "hey sup"; child runs + finishes (child log ok,
      full config now correct: max_tokens 2048, thinking 0); parent window
      stays blank, status "messages: busy"
- [x] root cause: child inherits the read-end of the pipe it reads its
      message from -> parent's `<$child_in>` never sees EOF -> done() never
      runs. close(0) in the child fixes it.
- [ ] retest end-to-end on :1 + xvfb, screenshot proof

## 2. desktop looks less mangled (local)
- [ ] fix mojibake: `Whatâs up?` - utf-8 bytes inserted into Tk as latin-1;
      decode utf-8 before insert (desktop path only; terminal is fine)
- [ ] hide/restyle protocol chatter in the transcript:
      - assistant tool fences -> not shown as plain user text
      - `result` blocks -> one subtle line, not a full JSON dump under `you>`
      - the nudge -> subtle sys line, not a fake user message
- [ ] verify on :1 with snap + tesseract

## 3. desktop streams the response (local)
- [ ] provider: chat_stream() - ollama NDJSON line callback; one-shot fallback
- [ ] http: incremental curl --no-buffer read (line callback)
- [ ] agent: token callback through chat_stream
- [ ] child: NDJSON event protocol (note / delta / final)
- [ ] desktop: open assistant bubble on first token, append deltas, close on
      final

## 4. rounds shouldn't just stop
- [x] loop nudges the model on no-tool replies (Agent.pm, no_tool_max=3)
- [ ] nudge must not appear as a user message (see 2)
- [ ] verify a multi-round task completes against qwen3.8

## 5. HP-UX machine (telnet localhost 2323, pane %136, nfs /mount/volatile/hpux)
- [ ] deploy latest to oa2, full suite green on 5.8.8
- [ ] compat-lint clean (new code must stay 5.006-safe)
- [ ] check reachability to 10.0.0.1:11434; if yes, live agent over raw sockets
- [ ] no Tk on the box -> desktop cannot run there; code must still compile +
      pass tests

## 6. oa-proxy (NEXT - read oa-proxy.md)
- [ ] modern-machine helper: https fetch (no TLS on old box), lightpanda ->
      markdown page conversion, screenshot capture (xwd->imagemagick->send)
- [ ] accept an mcp.json: any standard MCP server (context7, exa, ...) usable
      from oa through oa-proxy
- [ ] old box side: /proxy <ip>:<port> routes those calls
- [ ] language is irrelevant-ish: assume modern macOS/linux host

## 7. release v0.1.7
- [ ] bump version, full local suite + compat-lint + desktop smoke
- [ ] tag + push + release asset oldagent-0.1.7.tgz, verify download
