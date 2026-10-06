const DEFAULTS = { enabled: true, port: 47615, token: "", thresholdMB: 5 };

async function cookieHeader(url) {
  const cookies = await chrome.cookies.getAll({ url });
  return cookies.map((c) => `${c.name}=${c.value}`).join("; ");
}

// Resolves true only if Gom accepted the download within 2 seconds.
async function sendToGom(item, settings) {
  const url = item.finalUrl || item.url;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 2000);
  try {
    const res = await fetch(`http://127.0.0.1:${settings.port}/add`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Gom-Token": settings.token },
      body: JSON.stringify({
        url,
        filename: item.filename ? item.filename.split(/[\\/]/).pop() : undefined,
        referrer: item.referrer || undefined,
        cookies: await cookieHeader(url),
        userAgent: navigator.userAgent,
      }),
      signal: controller.signal,
    });
    return res.ok;
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

// Resolves true if Gom took the download and Chrome's copy was cancelled.
async function handOff(item) {
  const settings = await chrome.storage.local.get(DEFAULTS);
  const url = item.finalUrl || item.url;
  if (!settings.enabled || !settings.token) return false;
  if (!/^https?:/i.test(url)) return false; // blob:, data: etc. only exist inside the page
  // Response headers have arrived by now, so the size is known unless the server didn't send one.
  if (item.totalBytes > 0 && item.totalBytes < settings.thresholdMB * 1024 * 1024) return false;
  if (!(await sendToGom(item, settings))) return false; // Gom not running: let Chrome do it
  await chrome.downloads.cancel(item.id).catch(() => {});
  await chrome.downloads.erase({ id: item.id }).catch(() => {});
  return true;
}

// Runs before Chrome shows any Save As dialog (the PDF viewer always asks), and Chrome waits
// for suggest(). Cancelling here instead of in onCreated means that dialog never appears.
chrome.downloads.onDeterminingFilename.addListener((item, suggest) => {
  handOff(item)
    .catch(() => false)
    .then((handedOff) => {
      if (!handedOff) suggest();
    });
  return true; // suggest() is called asynchronously
});
