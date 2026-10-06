const DEFAULTS = { enabled: true, port: 47615, token: "", thresholdMB: 0 };
const $ = (id) => document.getElementById(id);
const showStatus = (text, ok = true) => {
  $("status").textContent = text;
  $("status").className = ok ? "ok" : "err";
};

chrome.storage.local.get(DEFAULTS).then((s) => {
  $("enabled").checked = s.enabled;
  $("port").value = s.port;
  $("token").value = s.token;
  $("thresholdMB").value = s.thresholdMB;
});

function readForm() {
  return {
    enabled: $("enabled").checked,
    port: Number($("port").value) || DEFAULTS.port,
    token: $("token").value.trim(),
    thresholdMB: Math.max(0, Number($("thresholdMB").value) || 0),
  };
}

$("save").onclick = async () => {
  await chrome.storage.local.set(readForm());
  showStatus("Saved.");
};

$("test").onclick = async () => {
  const s = readForm();
  try {
    const res = await fetch(`http://127.0.0.1:${s.port}/ping`, { headers: { "X-Gom-Token": s.token } });
    showStatus(res.ok ? "Connected to Gom ✓" : `Gom rejected the request (HTTP ${res.status}) – check the token.`, res.ok);
  } catch {
    showStatus("Can't reach Gom – is the app running on this port?", false);
  }
};
