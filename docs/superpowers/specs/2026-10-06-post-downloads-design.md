# Gom – Leave form-POST downloads to Chrome

Date: 2026-10-06 · Status: implemented

## 1. Goal

Gom fetches a handed-off download again with a plain GET. A download produced by submitting a form (POST) then breaks: the server rejects the GET or returns a different page. The extension should spot those downloads and let Chrome finish them, while every other download still goes to Gom.

**Out of scope:** replaying the POST body in Gom; POSTs made with `fetch`/XHR whose response becomes a `blob:` download (the existing `blob:` check already leaves those to Chrome).

## 2. Design

- **Detect** – a non-blocking `chrome.webRequest.onBeforeRequest` listener on `main_frame`/`sub_frame` requests (form submits arrive as one of these). It keeps an in-memory `Set` of URLs whose latest navigation used POST: a POST adds the URL, any other method removes it.
- **Gate** – `handOff` returns `false` (Chrome keeps the download) when `item.finalUrl || item.url` is in the set. Checking the final URL means the common POST → 303 → GET redirect still goes to Gom, because the request that produced the file was a GET Gom can repeat.
- **Permission** – `"webRequest"` is added to `manifest.json`.
- **Memory** – the set is never pruned. The MV3 service worker stops after ~30 s idle, which clears it, and navigation POSTs are rare.

## 3. Testing

No automated tests exist for the extension. Manual check with a local server that answers a form POST with an attachment (see `extension/README.md`): the file downloads in Chrome and Gom shows nothing; a normal large download still lands in Gom.
