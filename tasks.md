# task sheet

working order: local desktop first, then HP-UX, then release.
snapshots: use `DISPLAY=:1` (Xnest 1024x768) via xdotool + util/snap.pl + tesseract.

STATUS: 1-4 + 6 + 7 + 8 done. 5 (HP-UX) blocked - box is down (nothing on :2323).

## 8. desktop chat bubbles (local) - DONE
- [x] user messages: blue bubble, right-aligned, hugging the text (no band).
- [x] assistant messages: off-white bubble, left-aligned, hugging the text.
- [x] no `you>` / `agent>` prefixes; y-scrollbar only (no x-scrollbar); word wrap.
- [x] status line is a plain label (no ridge/sunken relief).
- [x] slash commands typed in the entry run and show in the transcript.
- [x] the band bug was a tag covering the end-of-line newline (Tk paints that
      across the whole display line). fix: tag the bubble text only, leave the
      newline untagged; leading spaces stay untagged so the white shows through.
- [x] right-push is now arithmetic (measured bubble width vs line capacity),
      not a live probe (this Tk's computed-index delete / index('end') are
      unreliable and left 6k-space garbage lines). measurement pass: each bubble
      measured in isolation on line 1, cached per transcript width.
- [x] a 2-space safety margin keeps short bubbles off the wrap boundary (a
      bubble sitting exactly at line capacity wraps to the next line).

## 1. desktop shows the reply (local) - DONE
- [x] root cause: child inherited the read-end of its own input pipe -> no EOF.
      close(0) in the child fixed it.
- [x] reworked to NDJSON child events (note/delta/round/final); parent streams
      without freezing and renders complete replies through markdown.

## 2. desktop looks less mangled (local) - DONE
- [x] transcript hides raw native tool markup / protocol noise; tool calls
      collapse to one-liners; nudge + result are subtle sys lines, not fake
      user messages. (commit 5b8d185 / fba18ea)
- [x] Protocol::visible() strips XML <function=...>, <|tool_call|> wrappers and
      bare {"tool":...} JSON from prose.
- [x] Tool path args tolerant of the names models use (path/file/file_path/...).

## 3. desktop streams the response (local) - DONE
- [x] child emits NDJSON events; parent parses line-by-line (non-blocking
      pipe, EAGAIN -> reschedule).
- [x] raw streamed tokens are a temporary bubble; `round` re-renders the final
      reply through the markdown formatter.

## 4. rounds shouldn't just stop - DONE
- [x] loop nudges the model on no-tool replies (Agent.pm, no_tool_max=3);
      nudge is a sys line, not a user message.

## 5. HP-UX machine (telnet localhost 2323, nfs /mount/volatile/hpux) - UNBLOCKED (box back up, not yet deployed)
- [x] box is back up: telnet localhost 2323, login chris / fixy2k, shell `-bash-3.2$`,
      tmux session `hpux`, nfs mount /mount/volatile/hpux. perl 5.8.8.
- [ ] deploy latest to /mount/volatile/hpux/oa2, full suite green on 5.8.8
- [ ] deploy latest to oa2, full suite green on 5.8.8
- [ ] compat-lint clean (new code stays 5.006-safe) - verified locally: 38 files
      clean, Proxy.pm 5.006-safe and only loaded when a proxy is set.
- [ ] check reachability to 10.0.0.1:11434; if yes, live agent over raw sockets

## 6. oa-proxy - DONE
- [x] oa-proxy service (modern perl): /status, /fetch (lightpanda markdown or
      raw), /req (HTTPS relay of any request), /mcp (stdio MCP servers),
      /shot (base64 image relay). All endpoints verified against live node +
      bash MCP servers, lightpanda, httpbin.
- [x] mcp.json: any stdio MCP server usable through oa-proxy
      (examples/mcp.json). Node pipe-buffering handled via file-stdout polling;
      newline framing was the actual blocker (fixed).
- [x] old box side: /proxy host:port routes https through the proxy;
      OldAgent::Proxy (5.006-safe, lazy-loaded); new fetch tool; /req relay so
      a legacy box can call a modern HTTPS provider.

## 7. release v0.1.7 - DONE (chat-bubble styling is a follow-up to it, not yet released)
- [x] bumped to 0.1.7; full local suite 269 ok, compat-lint 38 files clean,
      desktop smoke ok.
- [x] committed (fba18ea) + pushed over HTTPS (SSH key rejected).
- [x] release asset oldagent-0.1.7.tgz (46 files) uploaded; public download
      verified byte-identical (sha1 match) and standalone suite passes.
- note: an OpenRouter key that had been committed in a local-only diag file was
      removed before push (now reads $ENV{OPENROUTER_API_KEY}); that key should
      be rotated.
