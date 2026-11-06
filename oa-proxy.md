oa-proxy is a way for you to connect to the modern internet on the old machines which may lack curl, TLS 1.2 or ways to parse javascript reasonably. You run oa-proxy on a modern machine and then do /proxy <ip>:<port> in your oa session and it can now get https webpages, get pages converted to markdown through lightpanda, even send screenshots (oa will use the tools such as xwd and then imagemagick to convert it to a modern format before sending it off to your model). oa-proxy also accepts a mcp.json where you can connect any standard mcp server such as context7, exa web search, or anything else. oa will be able to use them through oa-proxy.

Start it on the modern machine with `oa-proxy --port 8470` (add `--mcp mcp.json` and `--lightpanda PATH` as needed). It prints how to reach it:

```
oa-proxy listening on 0.0.0.0:8470
  in oa on the old box, type one of:
    /proxy 10.0.0.126:8470
  or put  proxy = <address>:8470  in its ~/.oldagentrc
  can do: fetch and https relay; markdown via lightpanda; mcp: weather; screenshots to /tmp/oa-shots-1234
  each request is logged here; --verbose adds detail, --quiet silences all
00:31:55 10.0.0.43  POST /fetch https://example.com/  -> ok 1256b  0.4s
```

It listens on every interface. `--host 127.0.0.1` keeps it to that machine. On the old box, `oa --proxy 10.0.0.126:8470` is the same as typing `/proxy 10.0.0.126:8470` in the session.
