// Every kind of Wheel Studio export, made by the live page in headless Chrome:
// presets, every knob at both ends, worst-case text settings, random rolls and share links.
// usage: node scripts/studio-exports.mjs "$PWD/website/studio.html" Tests/Fixtures/studio-themes-all.json
// then:  Circularity.app/Contents/MacOS/Circularity --check-themes Tests/Fixtures/studio-themes-all.json
import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";
const [, , page, out, port = "9333"] = process.argv;
const chrome = spawn("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  ["--headless=new", `--remote-debugging-port=${port}`, "--user-data-dir=" + out + ".profile", "--no-first-run", "about:blank"], { stdio: "ignore" });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let ws;
for (let i = 0; i < 50 && !ws; i++) {
  await sleep(200);
  try {
    const list = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
    const t = list.find((x) => x.type === "page");
    if (t) ws = new WebSocket(t.webSocketDebuggerUrl);
  } catch {}
}
await new Promise((r) => ws.addEventListener("open", r));
let id = 0; const waiting = new Map(); const errors = [];
ws.addEventListener("message", (m) => {
  const d = JSON.parse(m.data);
  if (d.id && waiting.has(d.id)) { waiting.get(d.id)(d); waiting.delete(d.id); }
  if (d.method === "Runtime.exceptionThrown") errors.push(d.params.exceptionDetails.text + " " + (d.params.exceptionDetails.exception?.description || ""));
  if (d.method === "Runtime.consoleAPICalled" && d.params.type === "error") errors.push(d.params.args.map((a) => a.value ?? a.description).join(" "));
});
const send = (method, params = {}) => new Promise((r) => { const i = ++id; waiting.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const run = async (expr) => {
  const r = await send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true });
  if (r.result?.exceptionDetails) throw new Error(r.result.exceptionDetails.exception?.description || JSON.stringify(r.result.exceptionDetails));
  return r.result.result.value;
};
await send("Runtime.enable");
await send("Page.enable");
await send("Page.navigate", { url: "file://" + page });
await sleep(2500);
const result = await run(`(() => {
  const themes = [], links = [], notes = [];
  const take = (label) => { themes.push(JSON.parse(appJSON())); links.push(shareLink()); notes.push(label); };
  // 1. Every preset and built-in theme
  STUDIO_PRESETS.forEach((p) => { applyState(presetState(p), ""); take("preset " + p.name); });
  if (typeof APP_THEMES !== "undefined") APP_THEMES.forEach((t) => { applyState(valid(merge(DEFAULT, Object.assign({ theme: t.id }, t.set))), ""); take("app theme " + t.id); });
  // 2. Every knob at each end of its range, every choice, every switch
  for (const [path, key, r] of KEYS) {
    const vals = r.one ? r.one : r.bool ? [true, false] : r.hex ? ["#000000", "#FFFFFF", "#7F7F7F"] : r.hex0 ? ["", "#FFFFFF", "#000000"] : [r.lo, r.hi, (r.lo + r.hi) / 2];
    for (const layout of ["halo", "ring", "orbit"]) for (const v of vals) {
      const S = clone(DEFAULT); S.layout = layout; setP(S, path, v); applyState(valid(S), ""); take(layout + " " + key + "=" + v);
    }
  }
  // 3. The worst cases for text: biggest labels, widest spacing, every font, case and weight, every layout
  for (const layout of ["halo", "ring", "orbit"]) for (const font of ["rounded", "default", "mono"]) for (const c of ["title", "upper"]) for (const w of ["regular", "heavy"]) {
    const S = clone(DEFAULT); Object.assign(S, { layout, font, case: c, labelWeight: w, label: 1.3, track: 0.3, scale: 0.7, orb: 0.85, thick: 0.8, gap: 8, captions: true });
    applyState(valid(S), ""); take("stress " + [layout, font, c, w].join(" "));
    Object.assign(S, { scale: 1.4, orb: 1.15, thick: 1.2, bulge: 2.5, round: 1, fill: "stickers" }); applyState(valid(S), ""); take("stress big " + [layout, font, c, w].join(" "));
  }
  // 4. Lots of random rolls, as "Surprise me" makes them
  for (let i = 0; i < 400; i++) { surprise(); take("roll " + i); }
  return { themes, links, notes };
})()`);
// 5. Round trip: the app's JSON pasted into the Studio's Import box must give the same JSON back.
const roundTrip = await run(`(() => {
  const bad = [];
  const sample = ${JSON.stringify(result.themes.filter((_, i) => i % 7 === 0))};
  for (const t of sample) {
    document.querySelector("#importCode").value = JSON.stringify(t);
    document.querySelector("#importBtn").click();
    const back = JSON.parse(appJSON()).values;
    for (const [k, v] of Object.entries(t.values)) if (JSON.stringify(back[k]) !== JSON.stringify(v)) { bad.push(k + ": " + JSON.stringify(v) + " came back " + JSON.stringify(back[k])); break; }
  }
  return { checked: sample.length, bad };
})()`);
writeFileSync(out, JSON.stringify({ themes: result.themes, links: result.links }, null, 1));
writeFileSync(out + ".notes.json", JSON.stringify(result.notes));
console.log(`themes ${result.themes.length}, links ${result.links.length}; round trip ${roundTrip.checked - roundTrip.bad.length}/${roundTrip.checked}`);
roundTrip.bad.slice(0, 10).forEach((b) => console.log("ROUNDTRIP " + b));
errors.slice(0, 10).forEach((e) => console.log("PAGE ERROR " + e));
ws.close(); chrome.kill();
