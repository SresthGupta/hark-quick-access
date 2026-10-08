# Hark Quick Access

A tiny native macOS bar for [Hark](https://hark.com) that knows what tab you're on in [Yab](https://yetanotherbrowser.com).

Press **⌥ Space**, type, hit Enter. Your message goes to Hark with the front Yab tab's id, title, and URL attached, so Hark can read or act on that exact tab when it needs to. Nothing to copy or paste.

## How it works

- **Native bar first.** A 420×64 AppKit panel floats over every Space. No web view is loaded until you send.
- **Yab context via MCP.** On open, it spawns `yab mcp`, calls the `tabs` tool, and picks the `(in front)` user tab. Click the tab chip to leave it off.
- **Expands on send.** The full Hark chat opens docked on the right and your message is sent automatically, once.
- **Light on resources.** The web view is torn down 3 minutes after you collapse it. Idle footprint is about 95 MB and 0% CPU.
- **Read-only context.** It only lists tabs. Any action in the browser happens because you asked Hark for it.

## Shortcuts

| Keys | Action |
| --- | --- |
| ⌥ Space | Show or hide the bar (collapses the full chat if it's open) |
| ⌥ ⇧ Space | Open or collapse the full chat |
| Enter | Send |
| Esc | Hide the bar |

## Install

Needs macOS 13+, Xcode command line tools, and Yab's CLI at `~/.local/bin/yab`.

```bash
git clone https://github.com/SresthGupta/hark-quick-access.git
cd hark-quick-access
./build.sh
```

On first launch, paste the link of the Hark chat or project you want it to use. Change it later from the **H** in the menu bar.

## Notes

- Hark has no public chat API, so the chat itself is Hark's web app in a `WKWebView`. Everything around it is native Swift.
- Sending works by filling Hark's composer and pressing its send button, so a Hark UI change can break it.

MIT licensed.
