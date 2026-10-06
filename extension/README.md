# Gom Download Capture (Chrome / Arc / Brave / Edge)

## Install

1. Open `chrome://extensions` and turn on **Developer mode**.
2. Click **Load unpacked** and choose this `extension/` folder.
3. Open the extension's **Options**, paste the token from Gom → Settings → Copy, click **Save**, then **Test connection**.
4. In Chrome settings → Downloads, turn **off** "Ask where to save each file before downloading".

## Known limitations

- Downloads produced by submitting a form (POST) break, because Gom re-requests them with GET. Turn the extension off for those sites.
- Files below the threshold (default 5MB) stay in Chrome.

## Manual checklist

- [ ] Download a large ISO → it appears in Gom and disappears from Chrome's download list.
- [ ] Quit Gom, download a large file → Chrome keeps downloading it itself.
- [ ] Download a ~1MB file → Chrome downloads it, Gom shows nothing.
- [ ] Download a file that needs login (e.g. a large Google Drive file) → Gom downloads it.
- [ ] Put a wrong token in Options → **Test connection** reports an error.
