# Gom Download Capture (Chrome / Arc / Brave / Edge)

## Install

1. Open `chrome://extensions` and turn on **Developer mode**.
2. Click **Load unpacked** and choose this `extension/` folder.
3. Open the extension's **Options**, paste the token from Gom → Settings → Copy, click **Save**, then **Test connection**.
4. After editing any file here, click the reload icon on the extension's card in `chrome://extensions`.

## Known limitations

- Downloads produced by submitting a form (POST) stay in Chrome, because Gom can only re-request with GET. A form that redirects to a GET download (POST → 303) still goes to Gom.
- Files below the threshold (default 0, i.e. every file) stay in Chrome.

## Manual checklist

- [ ] Download a large ISO → it appears in Gom and disappears from Chrome's download list.
- [ ] Quit Gom, download a large file → Chrome keeps downloading it itself.
- [ ] Download a ~1MB file → Chrome downloads it, Gom shows nothing.
- [ ] Download a file that needs login (e.g. a large Google Drive file) → Gom downloads it.
- [ ] Submit a form that returns a file → Chrome downloads it, Gom shows nothing. Local test server: run the snippet below, open `http://127.0.0.1:8765`, click **Download**.
  ```sh
  python3 -c 'import http.server as h
  class H(h.BaseHTTPRequestHandler):
      def do_GET(s): s.send_response(200); s.end_headers(); s.wfile.write(b"<form method=post><button>Download</button></form>")
      def do_POST(s): s.send_response(200); s.send_header("Content-Disposition","attachment; filename=post.txt"); s.end_headers(); s.wfile.write(b"from POST\n")
  h.HTTPServer(("127.0.0.1",8765),H).serve_forever()'
  ```
- [ ] Put a wrong token in Options → **Test connection** reports an error.
