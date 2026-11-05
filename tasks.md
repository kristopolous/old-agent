# task sheet

working order: local desktop first, then HP-UX, then release.
snapshots: use `DISPLAY=:1` (Xnest 1024x768) via xdotool + util/snap.pl + tesseract.

STATUS: 1-13 done. 0.1.8 (this tree) is at /mount/volatile/hpux/oa2 (old tree
kept as oa2.0.1.5.bak); its suite is green there (279 ok, 3 skipped).

## 9. desktop chat is a chat (local) - DONE
the oa.png state: a "hello" became `[tool] d / [... clipped 0 chars ...] /
one summary=U ...`, `[tool] ```result`, `[tool] ````, and the window stuck
on busy/Thinking after the second message. five bugs, all fixed:
- [x] Util::clip with a limit under 200 computed keep=1 and returned
      head + "[... clipped 0 chars ...]" + the whole string. short limits
      are now a plain truncation (t/41-nudge.t).
- [x] a ```result message was rendered fences and all; now only the body.
- [x] a done block is the model signing off: no [tool]/[done] lines for it,
      and its summary stands in for the reply when there is no prose.
- [x] the loop nudged every reply that had no tool call, so a chat answer
      got "No tool call was emitted..." and the model invented a done
      block (or, with auto-approve, went looking for work in tasks.md).
      now: a reply without a tool call ends the turn; the nudge fires only
      when the reply narrates a step instead of taking it ("Let me read
      the file first"). "let me know" / "I'll be here" are sign-offs.
      the system prompt no longer says "you are NOT a chatbot".
- [x] ask_final_seen was never reset per turn, so from the second message
      on the poll loop stopped and the final event was ignored: busy
      forever. reset in _send.
- [x] Stop button: kills the child, keeps the message + whatever streamed.
- [x] agent bubble darkened (#f2f1ea was invisible on white), a thin gap
      line between bubbles.
- [x] markdown never rendered in the desktop: _render_md passed the tag
      list as a joined string ("plain,bold"), which Tk takes as ONE tag of
      that name. now an array ref. the bubble tag goes on the text too
      (it was only on the pad spaces, so the "bubble" was two marks).
      fence lines (```perl / ```) are hidden inside a bubble.
- verified live (qwen3.8 at 9ol.es): hello / just here for a chat! -> two
      prose replies, 4 messages, Send re-enabled; a list-tool turn renders
      as one [tool] line, one [list] line, the answer bubble.
- snapshot note: :1 (Xnest) captures come back black. capture under
      `xvfb-run -a -s "-screen 0 1024x768x24"` with `import -window <id>`.

## 10. real bubbles, and bash that comes back (local) - DONE
- [x] bubbles are embedded widgets now: the human's message is a padded
      blue Label on the right; the agent's reply is a padded grey Text box
      (hugs short replies, caps at two thirds of the width) with the
      markdown tags inside it. a text tag can only paint the cells it
      owns - no padding, no width - and its background ignores -rmargin
      (probed), so a tag-drawn bubble was never going to look like one.
      the whole probe/measure machinery (bubble widths, line capacity,
      space padding) is gone with it.
- [x] box height is computed from the font metrics (word-wrap simulation
      per token font): Tk only lays out the display lines of a widget that
      is on screen, so dlineinfo fails for exactly the tall bubbles. the
      live streamed bubble grows in place per delta (cached per line) -
      no full re-render per token; cheap enough for an old box.
- [x] tool lines show the call in full (a long command wraps under
      itself); a result is a status line plus the first 20 lines of
      output as a block, then "(N more lines)". no character ellipses.
- [x] a bash call never came back: the child inherited the terminal's
      stdin and blocked on "allow? [y]es" there. the child now sends an
      `ask` event and reads one line from a stdin pipe; the window shows
      Allow / Always / Deny and writes y / a / n.
- [x] ...and the event pipe was never non-blocking: `Fcntl::fcntl(...)`
      is not a function (fcntl is a builtin) and the eval hid it, so
      sysread blocked the whole window until the child wrote - a deadlock
      once the child was waiting on us. builtin fcntl now; verified
      O_NONBLOCK set.
- [x] the child's message (config, api key, transcript) went by argv,
      visible in `ps` to every user. it is the first line on the stdin
      pipe now. the key that was exposed should be rotated.
- [x] transcript_text(): the on-screen text, bubbles included, for the
      smoke test and the diagnostics.

## 11. no flashing, no resizing (local) - DONE
"flash flash flash, resize window, flash flash flash, response":
- [x] the window resized itself: the status label asked for the width of
      its text, and the busy line ("... THINKING...") was wider than the
      window, so Tk grew the toplevel, then shrank it back on the reply.
      the label is -width 1 + -fill x now, and the window size is pinned
      after the first layout (geometry = natural size); only the human
      resizes it.
- [x] the flashing was a full transcript rebuild (destroy + recreate every
      bubble widget) on every note / round / final. rendering is
      incremental now: an event is appended, a delta grows the live bubble
      in place, a round cuts the live bubble out and draws the finished
      reply at the same spot, and final does NOT redraw: the child emits
      its own result blocks and nudges as `umsg` events, so the screen
      already equals what the history renders to (verified identical on a
      live three-turn session with 56 deltas; 1 rebuild total, at
      startup).
- [x] a range deleted up to `end` includes the widget's undeletable final
      newline, and Tk then deletes the newline before the range instead -
      which ate the line break above every live bubble. `end-1c`.
- [x] the welcome text clears on the first message.
## 13. the NeXT: perl 5.001 on a 486 (OPENSTEP 4.2) - DONE, as oa1
the box: NeXT Mach 4.2 / OPENSTEP 4.2, i386 (486), 64 MB, perl 5.001, csh,
no cc, no uname, ftp + telnet, ollama reachable at 10.0.0.1:11434.
- [x] probed 5.001 (util: see t/97 lint list): no our / foreach my / qr /
      $f->() / 3-arg open / prototypes / UNIVERSAL::can / POSIX / IO /
      File::Spec / use vars; coderef signal handlers are ignored (named
      handlers only); Socket.pm has no inet_aton; gethostbyname rejects
      dotted quads; select($old) does not restore STDOUT.
- [x] decided: not a port (84 foreach my, 40 ->(), 35 module uses would
      drag the tree down to 1995) - a separate one-file `oa1` in the
      5.000 dialect, same protocol, same rc, a fake-ollama test (t/97).
- [x] live on the box: models / ask (5 s, 0.0u) / do (7 rounds to "a NeXT
      Computer running NeXTSTEP / OpenStep"). the desktop is out of
      scope there (no Tk, no X).
- [x] the REPL session where qwen said "I don't have access to external
      tools": ollama's /api/chat ignores a top-level `system` field, so the
      prompt never arrived - in oa1 AND in the main tree's ollama-native
      path (the HP-UX box uses openai-compat, which was fine). system
      message now; t/43 pins it. prompt: machine questions are answered
      with a command. with that, "tell me a bit about this machine" ran
      four probes + a read and concluded correctly.
- [x] `oa` decides by itself: `$] < 5.006` (checked before any `use`)
      execs `oa1` next to it. `oa doctor` on the NeXT: endpoint answers,
      qwen3.8 is one of 2 models. `--ascii` for the em-dash-as-"b" terminal.
      the tree lives at ~/oldagent on the box (ftp + gnutar).

## 12. plain text, for the PA-RISC box - DONE
the widget bubbles were still janky on HP-UX: a widget per message and a
font-measurement pass per word is real work on a 1990s CPU. so: no boxes.
- [x] one text widget, tags only. the human's lines are blue and
      right-aligned (-justify on a tag with no background paints no band),
      the agent's are plain with the markdown tags straight on the
      transcript, tool lines small and grey. nothing measured, no update()
      calls, Tk wraps the text itself.
- [x] streaming inserts each token before the live line's newline
      (end-2c); the round cuts the live text from its mark and draws the
      markdown reply there. still 0 rebuilds per turn, still screen ==
      history render (desk-trace, scripted + live).
- [x] ~130 lines of bubble machinery gone (embedded widgets, wrap
      simulation, height fitting, font-per-tag lookup).

- [x] HP-UX: "uninitialized value ... Provider.pm line 134" - the desktop
      child asks for streaming, stream_request's early returns (no curl)
      carried no `backend`, and the error string concatenated it. the
      early returns carry it now, the message guards it, and a box
      without curl never attempts streaming at all (HTTP::can_stream).

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

## 5. HP-UX machine (telnet localhost 2323, nfs /mount/volatile/hpux) - DONE
- [x] box is back up: telnet localhost 2323, login chris / fixy2k, shell `-bash-3.2$`,
      tmux session `hpux`, nfs mount /mount/volatile/hpux. perl 5.8.8.
- [x] current tree deployed to /mount/volatile/hpux/oa2 (the 0.1.5 tree is
      kept as oa2.0.1.5.bak). `prove -I lib t` on 5.8.8: all successful,
      279 tests, 3 files skipped (tty test, two desktop tests), 279s.
- [x] compat-lint clean, 40 files.
- [x] 10.0.0.1:11434 reachable; `./oa do "what kind of computer do I have"`
      answers in ~17s over the raw socket (HP 9000/778, HP-UX 11i v1).
- [x] the box's rc says `base_url = http://10.0.0.1:11434` (no /v1) with
      provider openai-compat: ollama 404s the dialect above /v1. oa now
      retries under /v1 on a 404 (one-shot, stream, and /models) and keeps
      using it; no config change needed. the 404 used to come back as an
      *empty reply* on the stream path.
- fixed on the way: `length undef` warning (Protocol.pm) on 5.8.8; the
      desktop tests BAIL_OUT'd the whole suite without xvfb (skip now); the
      tty approval test read whatever was typed into the pane as its answer
      (opt-in with OA_TTY_TEST=1 now).

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
