/* DeviceSpoofLabs WebUI 客户端（汉化 + 按应用作用域 + Zygisk 增强版） */
"use strict";

var BIN = "/data/adb/modules/devicespooflab/common/webctl.sh";
var CONFIG_FILES = [
  { name: "device_identity.conf", label: "品牌与机型属性 (device_identity.conf)", mode: "structured" },
  { name: "build_info.conf", label: "系统构建指纹 (build_info.conf)", mode: "structured" },
  { name: "identifiers.conf", label: "序列号与 IMEI (identifiers.conf)", mode: "structured" },
  { name: "custom.conf", label: "自定义扩展属性 (custom.conf)", mode: "raw" }
];

var STATE = null;
var EDIT_CONFIG_MODE = "standard"; // "standard" | "super"
var CONFIGS_LOADED = false;
var SCOPE_LOADED = false;
var EXTRAS_LOADED = false;
var SUPER_EXTRAS_LOADED = false;
var ANDROID_ID_LOADED = false;
var CONFIG_SAVE_TIMERS = {};
var EXTRAS_SAVE_TIMER = null;
var SUPER_EXTRAS_SAVE_TIMER = null;
var toastTimer = null;
var DEFAULT_TOAST_MS = 3500;
var REBOOT_TOAST_MS = 8000;

var SCOPE_STATE = { mode: "per_app", targets: [], superTargets: [] };
var EXTRAS_STATE = {};
var SUPER_EXTRAS_STATE = {};
var PICKER_MODE = "android_id"; // "scope" | "super_scope" | "android_id"

var cbCounter = 0;
function hasBridge() {
  return typeof ksu !== "undefined" && ksu && typeof ksu.exec === "function";
}

function exec(command, options) {
  options = options || {};
  return new Promise(function (resolve, reject) {
    if (!hasBridge()) { reject(new Error("no-bridge")); return; }
    var name = "dsl_cb_" + Date.now() + "_" + (cbCounter++);
    window[name] = function (errno, stdout, stderr) {
      delete window[name];
      resolve({ errno: errno, stdout: stdout || "", stderr: stderr || "" });
    };
    try {
      ksu.exec(command, JSON.stringify(options), name);
    } catch (e) {
      delete window[name];
      reject(e);
    }
  });
}

function $(sel, root) { return (root || document).querySelector(sel); }
function $all(sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }

function shQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }
function buildCmd(args) { return BIN + " " + args.map(shQuote).join(" "); }
function toB64(str) { return btoa(unescape(encodeURIComponent(str))); }

function fromB64(text) {
  var m = /^b64:([A-Za-z0-9+\/]*={0,2})$/.exec(String(text || "").replace(/\s+/g, ""));
  if (!m || m[1].length % 4 !== 0) return null;
  var bin;
  try { bin = atob(m[1]); } catch (e) { return null; }
  if (typeof TextDecoder !== "undefined") {
    var bytes = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return new TextDecoder("utf-8", { ignoreBOM: true }).decode(bytes);
  }
  try { return decodeURIComponent(escape(bin)); } catch (e) { return bin; }
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"]/g, function (c) {
    return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
  });
}

var overlayDepth = 0;
var overlayTimer = null;
var OVERLAY_QUIET_MS = 350;
function showOverlay(on) {
  var el = $("#overlay");
  overlayDepth = Math.max(0, overlayDepth + (on ? 1 : -1));
  if (overlayDepth === 0) {
    if (overlayTimer) { clearTimeout(overlayTimer); overlayTimer = null; }
    el.classList.add("hidden");
    el.classList.remove("quiet");
  } else if (el.classList.contains("hidden")) {
    el.classList.remove("hidden");
    el.classList.add("quiet");
    overlayTimer = setTimeout(function () {
      overlayTimer = null;
      el.classList.remove("quiet");
    }, OVERLAY_QUIET_MS);
  }
}

function toast(msg, options) {
  options = options || {};
  var bar = $("#toast-bar");
  var message = $("#toast-message");
  var reboot = $("#toast-reboot");
  if (!bar || !message || !reboot) {
    try { if (typeof ksu !== "undefined" && ksu && ksu.toast) ksu.toast(msg); } catch (e) {}
    return;
  }
  if (toastTimer) clearTimeout(toastTimer);
  message.textContent = msg;
  reboot.classList.toggle("hidden", !options.reboot);
  bar.classList.remove("hidden");

  toastTimer = setTimeout(function () {
    bar.classList.add("hidden");
    reboot.classList.add("hidden");
    toastTimer = null;
  }, options.reboot ? REBOOT_TOAST_MS : DEFAULT_TOAST_MS);
}

async function webctl() {
  var args = Array.prototype.slice.call(arguments);
  var r = await exec(buildCmd(["--b64"].concat(args)));
  var out = fromB64(r.stdout);
  var err = fromB64(r.stderr);
  if (out === null && r.errno === 0) r.errno = 1;
  if (out !== null) r.stdout = out;
  if (err !== null) r.stderr = err;
  return r;
}

async function webctlJSON() {
  var args = Array.prototype.slice.call(arguments);
  var r = await webctl.apply(null, args);
  var raw = (r.stdout || "").trim();
  var data;
  try {
    data = JSON.parse(raw);
  } catch (e) {
    data = { ok: r.errno === 0, message: raw || (r.stderr || "").trim(), _parseError: true };
  }
  data._errno = r.errno;
  data._raw = raw;
  data._stderr = (r.stderr || "").trim();
  return data;
}

function uiLog(msg) {
  try { webctl("ui-log", toB64(String(msg))); } catch (e) {}
}

async function openExternalUrl(url) {
  try {
    var res = await webctlJSON("open-url", toB64(url));
    if (res && res.ok === false) toast(res.message || "无法打开链接");
  } catch (e) {
    toast("无法打开链接");
  }
}

function delay(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
function markRebootUI() { if (STATE) STATE.reboot_required = true; }
function hasActivePersona() { return !!(STATE && STATE.active_persona); }
function hasActiveSuperPersona() { return !!(STATE && STATE.active_super_persona); }
function hasActiveAnyPersona() { return hasActivePersona() || hasActiveSuperPersona(); }
function statusIsUsable(s) {
  return !!s && s._errno === 0 && !s._parseError && typeof s.persona_active !== "undefined";
}

var STATUS_RETRIES = 3;

async function refresh() {
  showOverlay(true);
  try {
    var s = null, attempt = 0;
    for (attempt = 1; attempt <= STATUS_RETRIES; attempt++) {
      s = await webctlJSON("status");
      if (statusIsUsable(s)) break;
      if (attempt < STATUS_RETRIES) await delay(400 * attempt);
    }

    if (statusIsUsable(s)) {
      STATE = s;
      hideStatusError();
      renderStatus();
      if (attempt > 1) uiLog("status recovered on attempt " + attempt);
    } else {
      showStatusError();
      uiLog("status read failed after " + STATUS_RETRIES + " tries: errno=" + (s && s._errno));
    }
  } catch (e) {
    showNoBridge();
    uiLog("status read threw (bridge): " + (e && e.message ? e.message : String(e)));
  } finally {
    showOverlay(false);
  }
}

function renderStatus() {
  if (!STATE) return;
  $("#app-version").textContent = STATE.version || "—";
  $("#settings-version").textContent = STATE.version || "—";

  var pill = $("#persona-status");
  if (STATE.persona_active) {
    pill.textContent = "已激活";
    pill.className = "status-pill status-active";
  } else {
    pill.textContent = "未启用";
    pill.className = "status-pill status-inactive";
  }

  var badge = $("#scope-mode-badge");
  if (badge) {
    if (STATE.persona_active) {
      var modeLabel = STATE.scope_mode === "per_app"
        ? "标准按应用 · " + (STATE.scope_targets || 0) + " 个应用"
        : "全局生效（开机 resetprop）";
      badge.textContent = modeLabel;
      badge.classList.remove("hidden");
    } else {
      badge.classList.add("hidden");
    }
  }

  var quick = $("#dash-quick-actions");
  if (quick) quick.classList.toggle("hidden", !STATE.persona_active);

  var nameEl = $("#persona-active-name");
  if (nameEl) {
    if (STATE.persona_active && STATE.active_persona_name) {
      nameEl.textContent = STATE.active_persona_name;
      nameEl.classList.remove("hidden");
    } else {
      nameEl.classList.add("hidden");
    }
  }

  var spPill = $("#super-status");
  if (spPill) {
    if (STATE.super_active) {
      spPill.textContent = "已启用";
      spPill.className = "status-pill status-active";
    } else {
      spPill.textContent = "未开启";
      spPill.className = "status-pill status-inactive";
    }
  }
  var spBadge = $("#super-scope-badge");
  if (spBadge) {
    if (STATE.super_active) {
      spBadge.textContent = "超级目标 · " + (STATE.super_scope_targets || 0) + " 个应用";
      spBadge.classList.remove("hidden");
    } else {
      spBadge.classList.add("hidden");
    }
  }
  var spNameEl = $("#super-active-name");
  if (spNameEl) {
    if (STATE.super_active && STATE.active_super_persona_name) {
      spNameEl.textContent = STATE.active_super_persona_name;
      spNameEl.classList.remove("hidden");
    } else {
      spNameEl.classList.add("hidden");
    }
  }
  var spSumEl = $("#super-hardware-summary");
  if (spSumEl) {
    var ss = STATE.super_summary || {};
    var sumBits = [];
    if (ss.model) sumBits.push("型号 " + ss.model);
    if (ss.cpu_profile) sumBits.push("CPU " + ss.cpu_profile);
    if (ss.ram_gb && ss.storage_gb) sumBits.push(ss.ram_gb + "GB/" + ss.storage_gb + "GB");
    if (ss.gpu) sumBits.push(ss.gpu);
    if (ss.us_mode) sumBits.push("一键美区(US)");
    if (STATE.super_active && sumBits.length) {
      spSumEl.textContent = sumBits.join(" · ");
      spSumEl.classList.remove("hidden");
    } else {
      spSumEl.classList.add("hidden");
    }
  }
  var spFsBtn = $("#btn-dash-super-forcestop");
  if (spFsBtn) spFsBtn.classList.toggle("hidden", !STATE.super_active);

  var autoOff = $("#auto-disabled");
  if (autoOff) {
    if (STATE.auto_disabled && !STATE.persona_active) {
      autoOff.textContent = (STATE.auto_disabled_name ? "“" + STATE.auto_disabled_name + "”" : "该身份") +
        "已自动关闭：由于连续两次开启后未完成正常开机，保护机制已停用该身份。可在“设备身份”页重新启用。";
      autoOff.classList.remove("hidden");
    } else {
      autoOff.classList.add("hidden");
    }
  }

  var zyEl = $("#settings-zygisk");
  if (zyEl) zyEl.textContent = STATE.zygisk_ready ? "已就绪 (arm64-v8a / armeabi-v7a)" : "未检测到 .so";
  var scEl = $("#settings-scope");
  if (scEl) scEl.textContent = (STATE.scope_mode === "per_app"
    ? "标准：按应用 (" + (STATE.scope_targets || 0) + " 个)"
    : "标准：全局开机") + " · 超级：" + (STATE.super_scope_targets || 0) + " 个";
  $("#settings-unsafe").textContent = STATE.unsafe_props ? "已开启（绕过全局白名单）" : "关闭（安全默认）";
  $("#settings-backup").textContent = STATE.has_backup ? "已备份原机属性" : "尚未备份（首次激活时自动备份）";

  renderValues();
}

function renderValues() {
  var wrap = $("#values-table");
  wrap.innerHTML = "";
  var values = STATE.values || [];

  $("#values-note").textContent = STATE.scope_mode === "per_app"
    ? "当前为“按应用生效”模式：下方显示系统全局真实值，带“按应用托管”标签的参数仅在已勾选的目标应用内被替换为所配置的值。"
    : "当前为“全局生效”模式：实时值即系统全局返回值，若与目标配置不同则提示重启生效。";

  if (!values.length) {
    var empty = document.createElement("div");
    empty.className = "muted-note";
    empty.textContent = "当前环境无法读取实时系统属性。";
    wrap.appendChild(empty);
    return;
  }

  values.forEach(function (v) {
    var row = document.createElement("div");
    row.className = "value-row";

    var label = document.createElement("div");
    label.className = "value-label";
    label.appendChild(document.createTextNode(v.label));

    var sp = Number(v.spoofable);
    if (sp === 0) {
      var tag = document.createElement("span");
      tag.className = "tag tag-hw";
      tag.textContent = "保持真机";
      label.appendChild(tag);
    } else if (sp === 2 && STATE.persona_active && v.configured) {
      var appTag = document.createElement("span");
      appTag.className = "tag tag-app";
      appTag.textContent = "按应用生效";
      label.appendChild(appTag);
    } else if (sp === 1 && STATE.persona_active && v.configured && v.live !== v.configured) {
      var pend = document.createElement("span");
      pend.className = "tag tag-pending";
      pend.textContent = "待重启生效";
      label.appendChild(pend);
    }

    var live = document.createElement("div");
    live.className = "value-live";
    live.textContent = v.live || "—";

    row.appendChild(label);
    row.appendChild(live);

    if (sp === 2 && STATE.persona_active && v.configured && v.configured !== v.live) {
      var targetVal = document.createElement("div");
      targetVal.className = "value-orig";
      targetVal.innerHTML = "目标应用内伪装为：<b>" + escapeHtml(v.configured) + "</b>";
      row.appendChild(targetVal);
    } else if (v.original && v.original !== v.live) {
      var orig = document.createElement("div");
      orig.className = "value-orig";
      orig.innerHTML = "真机原值：<b>" + escapeHtml(v.original) + "</b>";
      row.appendChild(orig);
    }

    wrap.appendChild(row);
  });
}

function showNoBridge() {
  $("#no-bridge").classList.remove("hidden");
  $("#persona-status").textContent = "不可用";
  toast("WebUI 桥接不可用，请使用命令行 devicespooflabs");
}

function showStatusError() {
  var pill = $("#persona-status");
  pill.textContent = "状态读取失败";
  pill.className = "status-pill status-error";
  var banner = $("#status-error");
  if (banner) banner.classList.remove("hidden");
  $("#values-note").textContent = "无法读取模块状态，请到“设置 > 查看日志”核对，或点击重试。";
  $("#values-table").innerHTML = "";
  toast("读取状态失败，请点击重试");
}

function hideStatusError() {
  var banner = $("#status-error");
  if (banner) banner.classList.add("hidden");
}

async function runAction(action) {
  showOverlay(true);
  try {
    var res = await webctlJSON(action);
    uiLog("action " + action + ": errno=" + res._errno + " ok=" + (res.ok !== false));
    if (res.message) toast(res.message, { reboot: !!res.reboot_required });
    else if (res.reboot_required) toast("需要重启设备生效。", { reboot: true });
    await refresh();
  } catch (e) {
    toast("操作失败");
    uiLog("action " + action + " threw: " + (e && e.message ? e.message : String(e)));
  } finally {
    showOverlay(false);
  }
}

async function doReboot() {
  toast("正在重启手机…");
  try { await webctl("reboot"); } catch (e) {}
}

// ---------------------------------------------------------------------------
// 随机值生成器（JS 本地 + 合法 Luhn IMEI）
// ---------------------------------------------------------------------------

function randHex(len) {
  var bytes = new Uint8Array(Math.ceil(len / 2)), out = "", i;
  if (window.crypto && window.crypto.getRandomValues) window.crypto.getRandomValues(bytes);
  else for (i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256);
  for (i = 0; i < bytes.length; i++) out += ("0" + bytes[i].toString(16)).slice(-2);
  return out.slice(0, len);
}

function genHex16() { return randHex(16); }

function genRandomMac() {
  var h = randHex(12);
  var b0 = h.charAt(0) + "2"; // locally administered unicast
  return [b0, h.slice(2, 4), h.slice(4, 6), h.slice(6, 8), h.slice(8, 10), h.slice(10, 12)].join(":");
}

function genRandomUuid() {
  var h = randHex(32);
  return h.slice(0, 8) + "-" + h.slice(8, 12) + "-4" + h.slice(13, 16) + "-a" + h.slice(17, 20) + "-" + h.slice(20, 32);
}

function genRandomSerial() {
  var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", out = "", i;
  var bytes = new Uint8Array(12);
  if (window.crypto && window.crypto.getRandomValues) window.crypto.getRandomValues(bytes);
  else for (i = 0; i < 12; i++) bytes[i] = Math.floor(Math.random() * 256);
  for (i = 0; i < 12; i++) out += chars.charAt(bytes[i] % chars.length);
  return out;
}

function genLuhnImei() {
  var tacs = ["86194205", "86743206", "35418912", "35897211", "86391405", "35621810"];
  var tac = tacs[Math.floor(Math.random() * tacs.length)];
  var body = tac;
  for (var i = 0; i < 6; i++) body += String(Math.floor(Math.random() * 10));
  var sum = 0;
  for (var idx = 0; idx < 14; idx++) {
    var d = parseInt(body.charAt(idx), 10);
    if (idx % 2 === 1) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
  }
  var chk = (10 - (sum % 10)) % 10;
  return body + String(chk);
}

// ---------------------------------------------------------------------------
// 结构化配置文件编辑器
// ---------------------------------------------------------------------------

function parseConfig(text) {
  var hadTrailingNL = text.length > 0 && text.charAt(text.length - 1) === "\n";
  var rawLines = text.split("\n");
  if (hadTrailingNL) rawLines.pop();

  var lines = rawLines.map(function (line) {
    if (line === "FILE_ENABLED") return { type: "file", enabled: true };
    if (line === "FILE_DISABLED") return { type: "file", enabled: false };
    var trimmed = line.trim();
    if (trimmed === "" || trimmed.charAt(0) === "#") return { type: "raw", text: line };
    var m = line.match(/^(ENABLED|DISABLED),([^,]+),([\s\S]*)$/);
    if (m) return { type: "prop", status: m[1], prop: m[2], value: m[3] };
    return { type: "raw", text: line };
  });
  return { lines: lines, hadTrailingNL: hadTrailingNL };
}

function serializeConfig(model) {
  var out = model.lines.map(function (l) {
    if (l.type === "file") return l.enabled ? "FILE_ENABLED" : "FILE_DISABLED";
    if (l.type === "prop") return l.status + "," + l.prop + "," + l.value;
    return l.text;
  });
  return out.join("\n") + (model.hadTrailingNL ? "\n" : "");
}

function stripConfigNotes(text) {
  var lines = text.split("\n").filter(function (line) {
    var trimmed = line.trim();
    return trimmed !== "" && trimmed.charAt(0) !== "#";
  });
  return lines.join("\n") + (lines.length ? "\n" : "");
}

function makeSwitch(checked, onChange) {
  var label = document.createElement("label");
  label.className = "switch";
  var input = document.createElement("input");
  input.type = "checkbox";
  input.checked = !!checked;
  input.addEventListener("change", function () { onChange(input.checked); });
  var slider = document.createElement("span");
  slider.className = "slider";
  label.appendChild(input);
  label.appendChild(slider);
  return label;
}

function makeCfgHead(labelText) {
  var head = document.createElement("div");
  head.className = "cfg-file-head";
  var title = document.createElement("span");
  title.className = "cfg-file-name";
  title.textContent = labelText;
  head.appendChild(title);
  var tools = document.createElement("div");
  tools.className = "cfg-file-tools";
  var saved = document.createElement("span");
  saved.className = "cfg-saved";
  tools.appendChild(saved);
  head.appendChild(tools);
  return { head: head, tools: tools, saved: saved };
}

function setCfgSaved(el, text, cls) {
  if (!el) return;
  el.textContent = text || "";
  el.className = "cfg-saved" + (cls ? " " + cls : "");
}

function scheduleConfigSave(name, getContent, indicator, targetMode) {
  var mode = targetMode || EDIT_CONFIG_MODE || "standard";
  var key = mode + ":" + name;
  setCfgSaved(indicator, "编辑中…", "is-pending");
  if (CONFIG_SAVE_TIMERS[key]) clearTimeout(CONFIG_SAVE_TIMERS[key]);
  CONFIG_SAVE_TIMERS[key] = setTimeout(function () {
    CONFIG_SAVE_TIMERS[key] = null;
    saveConfigNow(name, getContent, indicator, mode);
  }, 700);
}

async function saveConfigNow(name, getContent, indicator, targetMode) {
  var mode = targetMode || EDIT_CONFIG_MODE || "standard";
  setCfgSaved(indicator, "保存中…", "is-pending");
  try {
    var res = await webctlJSON("write-config", name, toB64(getContent()), mode);
    if (res && res.ok === false) {
      setCfgSaved(indicator, "保存失败", "is-error");
      toast(res.message || "保存失败");
      return;
    }
    setCfgSaved(indicator, "已保存", "is-ok");
    if (res && res.reboot_required) markRebootUI();
    setTimeout(function () {
      if (indicator && indicator.classList.contains("is-ok")) setCfgSaved(indicator, "", "");
    }, 2200);
  } catch (e) {
    setCfgSaved(indicator, "保存失败", "is-error");
    toast("自动保存失败");
  }
}

function renderStructuredEditor(cf, model, targetMode) {
  var name = cf.name;
  var mode = targetMode || EDIT_CONFIG_MODE || "standard";
  var fileEl = document.createElement("div");
  fileEl.className = "cfg-file";

  var h = makeCfgHead(cf.label || name);
  var save = function () {
    scheduleConfigSave(name, function () { return serializeConfig(model); }, h.saved, mode);
  };

  if (name === "identifiers.conf") {
    var randBtn = document.createElement("button");
    randBtn.className = "btn btn-sm";
    randBtn.type = "button";
    randBtn.textContent = "随机序列号/IMEI";
    randBtn.addEventListener("click", function () {
      var ser = genRandomSerial();
      var imei = genLuhnImei();
      model.lines.forEach(function (l) {
        if (l.type !== "prop") return;
        if (l.prop === "ro.serialno") l.value = ser;
        else if (l.prop === "persist.radio.imei" || l.prop === "ro.ril.oem.imei") l.value = imei;
      });
      $all(".cfg-row", fileEl).forEach(function (row) {
        var pEl = row.querySelector(".cfg-prop");
        var iEl = row.querySelector("input[type='text']");
        if (!pEl || !iEl) return;
        if (pEl.textContent === "ro.serialno") iEl.value = ser;
        else if (pEl.textContent === "persist.radio.imei" || pEl.textContent === "ro.ril.oem.imei") iEl.value = imei;
      });
      if (mode === "super" && $("#sp-boot-serial")) {
        $("#sp-boot-serial").value = ser;
        if ($("#sp-fake-imei")) $("#sp-fake-imei").value = imei;
        SUPER_EXTRAS_STATE = SUPER_EXTRAS_STATE || {};
        SUPER_EXTRAS_STATE.SPOOF_BOOT_SERIAL = ser;
        SUPER_EXTRAS_STATE.FAKE_IMEI = imei;
        scheduleSuperExtrasSave();
      } else if (mode === "standard" && $("#ex-boot-serial")) {
        $("#ex-boot-serial").value = ser;
        EXTRAS_STATE.SPOOF_BOOT_SERIAL = ser;
        scheduleExtrasSave();
      }
      save();
      toast("已生成新的随机序列号与 Luhn 校验 IMEI（请同步开启对应开关）");
    });
    h.tools.insertBefore(randBtn, h.saved);
  }

  var fileMarker = model.lines.filter(function (l) { return l.type === "file"; })[0];
  if (fileMarker) {
    h.tools.appendChild(makeSwitch(fileMarker.enabled, function (on) { fileMarker.enabled = on; save(); }));
  }
  fileEl.appendChild(h.head);

  var rows = document.createElement("div");
  rows.className = "cfg-rows";

  model.lines.forEach(function (l) {
    if (l.type !== "prop") return;

    var row = document.createElement("div");
    row.className = "cfg-row";
    row.appendChild(makeSwitch(l.status === "ENABLED", function (on) {
      l.status = on ? "ENABLED" : "DISABLED";
      save();
    }));

    var main = document.createElement("div");
    main.className = "cfg-row-main";
    var propName = document.createElement("div");
    propName.className = "cfg-prop";
    propName.textContent = l.prop;
    var valWrap = document.createElement("div");
    valWrap.className = "cfg-val";
    var input = document.createElement("input");
    input.type = "text";
    input.value = l.value;
    input.spellcheck = false;
    input.autocapitalize = "none";
    input.addEventListener("input", function () { l.value = input.value; save(); });
    valWrap.appendChild(input);
    main.appendChild(propName);
    main.appendChild(valWrap);
    row.appendChild(main);
    rows.appendChild(row);
  });

  fileEl.appendChild(rows);
  return fileEl;
}

function renderRawEditor(cf, text, targetMode) {
  var name = cf.name;
  var mode = targetMode || EDIT_CONFIG_MODE || "standard";
  var fileEl = document.createElement("div");
  fileEl.className = "cfg-file";
  var h = makeCfgHead(cf.label || name);
  fileEl.appendChild(h.head);

  var rows = document.createElement("div");
  rows.className = "cfg-rows";
  var ta = document.createElement("textarea");
  ta.className = "cfg-textarea";
  ta.spellcheck = false;
  ta.placeholder = "示例：\nFILE_ENABLED\nENABLED,ro.product.marketname,Xiaomi 14";
  ta.value = stripConfigNotes(text);
  ta.addEventListener("input", function () {
    scheduleConfigSave(name, function () { return ta.value; }, h.saved, mode);
  });
  rows.appendChild(ta);
  fileEl.appendChild(rows);
  return fileEl;
}

function updateConfigModeBar() {
  var stdOk = hasActivePersona();
  var supOk = hasActiveSuperPersona();
  if (EDIT_CONFIG_MODE === "super" && !supOk && stdOk) EDIT_CONFIG_MODE = "standard";
  else if (EDIT_CONFIG_MODE === "standard" && !stdOk && supOk) EDIT_CONFIG_MODE = "super";

  var stdBtn = $("#btn-cfg-mode-std");
  var supBtn = $("#btn-cfg-mode-super");
  var hint = $("#config-mode-hint");
  if (stdBtn) {
    stdBtn.disabled = !stdOk;
    stdBtn.classList.toggle("is-active", EDIT_CONFIG_MODE === "standard");
  }
  if (supBtn) {
    supBtn.disabled = !supOk;
    supBtn.classList.toggle("is-active", EDIT_CONFIG_MODE === "super");
  }
  if (hint) {
    if (EDIT_CONFIG_MODE === "super" && supOk) {
      hint.textContent = "正在编辑【超级伪装】" + (STATE.active_super_persona_name || "超级新机") + " 的 .conf 文件";
    } else if (stdOk) {
      hint.textContent = "正在编辑【默认标准模式】" + (STATE.active_persona_name || "标准机型") + " 的 .conf 文件";
    } else {
      hint.textContent = "请先激活任意机型再编辑 .conf 属性文件";
    }
  }
}

async function loadConfigEditors() {
  updateConfigModeBar();
  if (CONFIGS_LOADED) return;
  var container = $("#config-editors");
  if (!container) return;
  container.innerHTML = "";
  var mode = EDIT_CONFIG_MODE;
  if ((mode === "super" && !hasActiveSuperPersona()) || (mode === "standard" && !hasActivePersona())) {
    CONFIGS_LOADED = true;
    return;
  }
  showOverlay(true);
  try {
    for (var i = 0; i < CONFIG_FILES.length; i++) {
      var cf = CONFIG_FILES[i];
      var r = await webctl("read-config", cf.name, mode);
      if (r.errno !== 0) continue;
      var text = r.stdout.replace(/\r\n?/g, "\n");
      if (cf.mode === "raw") {
        container.appendChild(renderRawEditor(cf, text, mode));
      } else {
        container.appendChild(renderStructuredEditor(cf, parseConfig(text), mode));
      }
    }
    CONFIGS_LOADED = true;
  } catch (e) {
    toast("无法加载配置文件");
  } finally {
    showOverlay(false);
  }
}

function resetConfigEditors() {
  CONFIGS_LOADED = false;
  SCOPE_LOADED = false;
  EXTRAS_LOADED = false;
  SUPER_EXTRAS_LOADED = false;
  ANDROID_ID_LOADED = false;
  var c = $("#config-editors");
  if (c) c.innerHTML = "";
}

// ---------------------------------------------------------------------------
// 作用模式与目标应用 (config/scope.conf & super_config/scope.conf)
// ---------------------------------------------------------------------------

function updateScopeUI() {
  var perEl = $("#mode-per-app");
  var glbEl = $("#mode-global");
  if (perEl) perEl.checked = (SCOPE_STATE.mode !== "global");
  if (glbEl) glbEl.checked = (SCOPE_STATE.mode === "global");
  var cntEl = $("#scope-target-count");
  if (cntEl) cntEl.textContent = "已选 " + SCOPE_STATE.targets.length + " 个应用";
  var spCntEl = $("#super-scope-target-count");
  if (spCntEl) spCntEl.textContent = "已选 " + SCOPE_STATE.superTargets.length + " 个应用";
  var pStd = $("#personas-std-scope-count");
  if (pStd) pStd.textContent = "已选 " + SCOPE_STATE.targets.length + " 个应用";
  var pSup = $("#personas-super-scope-count");
  if (pSup) pSup.textContent = "已选 " + SCOPE_STATE.superTargets.length + " 个应用";
  if (PICKER_MODE === "scope" || PICKER_MODE === "super_scope") updatePickerCount();
}

function buildScopePayload() {
  var lines = ["MODE=" + (SCOPE_STATE.mode === "global" ? "global" : "per_app")];
  SCOPE_STATE.targets.forEach(function (p) { lines.push("PKG=" + p); });
  return lines.join("\n") + "\n";
}

function buildSuperScopePayload() {
  var lines = ["MODE=per_app"];
  SCOPE_STATE.superTargets.forEach(function (p) { lines.push("PKG=" + p); });
  return lines.join("\n") + "\n";
}

async function saveScopeNow() {
  try {
    var res = await webctlJSON("set-scope", toB64(buildScopePayload()));
    if (res && res.ok === false) {
      toast(res.message || "保存标准目标列表失败");
      return;
    }
    if (res && res.message) toast(res.message, { reboot: !!res.reboot_required });
    await refresh();
  } catch (e) {
    toast("保存标准目标列表失败");
  }
}

async function saveSuperScopeNow() {
  try {
    var res = await webctlJSON("set-super-scope", toB64(buildSuperScopePayload()));
    if (res && res.ok === false) {
      toast(res.message || "保存超级伪装目标列表失败");
      return;
    }
    if (res && res.message) toast(res.message);
    await refresh();
  } catch (e) {
    toast("保存超级伪装目标列表失败");
  }
}

async function loadScopeConfig(force) {
  if (SCOPE_LOADED && !force) return;
  try {
    var c = await webctlJSON("scope-config");
    if (c && c.ok !== false && !c._parseError) {
      SCOPE_STATE.mode = (c.mode === "global") ? "global" : "per_app";
      SCOPE_STATE.targets = Array.isArray(c.targets) ? c.targets.slice() : [];
      SCOPE_STATE.superTargets = Array.isArray(c.super_targets) ? c.super_targets.slice() : [];
    }
  } catch (e) {}
  updateScopeUI();
  SCOPE_LOADED = true;
}

async function forceStopTargets(mode) {
  showOverlay(true);
  try {
    var res = await webctlJSON("force-stop-targets", mode || "all");
    toast(res.message || (res.ok === false ? "强杀失败" : "已完成"));
  } catch (e) {
    toast("强杀目标应用失败");
  } finally {
    showOverlay(false);
  }
}

async function syncAiTargets() {
  showOverlay(true);
  try {
    var res = await webctlJSON("sync-ai-targets");
    if (res && res.message) toast(res.message, { reboot: !!res.reboot_required });
    ANDROID_ID_LOADED = false;
    await loadAndroidIdConfig();
  } catch (e) {
    toast("同步失败");
  } finally {
    showOverlay(false);
  }
}

// ---------------------------------------------------------------------------
// Zygisk 进程级增强伪装 (extras.conf)
// ---------------------------------------------------------------------------

function collectExtrasFromUI() {
  return {
    BUILD_EXTRA_ENABLED: $("#ex-build-extra").checked ? "1" : "0",
    SPOOF_DEVICE: $("#ex-device").value.trim(),
    SPOOF_NAME: $("#ex-name").value.trim(),
    SPOOF_BOARD: $("#ex-board").value.trim(),
    SPOOF_PLATFORM: $("#ex-platform").value.trim(),
    SPOOF_HARDWARE: $("#ex-hardware").value.trim(),
    SPOOF_SOC_MANUF: $("#ex-soc-manuf").value.trim(),
    SPOOF_SOC_MODEL: $("#ex-soc-model").value.trim(),
    SPOOF_BOOT_SERIAL: $("#ex-boot-serial").value.trim(),
    SPOOF_SECURITY_PATCH: $("#ex-sec-patch").value.trim(),
    GPU_ENABLED: $("#ex-gpu-on").checked ? "1" : "0",
    GL_VENDOR: $("#ex-gl-vendor").value.trim(),
    GL_RENDERER: $("#ex-gl-renderer").value.trim(),
    GL_VERSION: $("#ex-gl-version").value.trim(),
    MAC_ENABLED: $("#ex-mac-on").checked ? "1" : "0",
    MAC_ADDR: $("#ex-mac-addr").value.trim().toLowerCase(),
    DRM_ENABLED: $("#ex-drm-on").checked ? "1" : "0",
    DRM_ID: $("#ex-drm-id").value.trim().toLowerCase(),
    UNAME_ENABLED: $("#ex-uname-on").checked ? "1" : "0",
    UNAME_RELEASE: $("#ex-uname-rel").value.trim(),
    UNAME_VERSION: $("#ex-uname-ver").value.trim(),
    BOOT_ID_MODE: $("#ex-bootid-mode").value || "off",
    BOOT_ID_VALUE: $("#ex-bootid-val").value.trim().toLowerCase(),
    SUPER_SPOOF_ENABLED: "0"
  };
}

function collectSuperExtrasFromUI() {
  var base = Object.assign({}, SUPER_EXTRAS_STATE || {});
  base.SUPER_SPOOF_ENABLED = $("#sp-master-on") && $("#sp-master-on").checked ? "1" : "0";
  base.US_MODE_ENABLED = $("#sp-us-on") && $("#sp-us-on").checked ? "1" : "0";
  base.US_PRESET = $("#sp-us-preset") ? $("#sp-us-preset").value : (base.US_PRESET || "tmobile_la");
  base.BUILD_EXTRA_ENABLED = $("#sp-build-extra") && $("#sp-build-extra").checked ? "1" : "0";
  if ($("#sp-device")) base.SPOOF_DEVICE = $("#sp-device").value.trim();
  if ($("#sp-name")) base.SPOOF_NAME = $("#sp-name").value.trim();
  if ($("#sp-board")) base.SPOOF_BOARD = $("#sp-board").value.trim();
  if ($("#sp-platform")) base.SPOOF_PLATFORM = $("#sp-platform").value.trim();
  if ($("#sp-hardware")) base.SPOOF_HARDWARE = $("#sp-hardware").value.trim();
  if ($("#sp-soc-manuf")) base.SPOOF_SOC_MANUF = $("#sp-soc-manuf").value.trim();
  if ($("#sp-soc-model")) base.SPOOF_SOC_MODEL = $("#sp-soc-model").value.trim();
  if ($("#sp-boot-serial")) base.SPOOF_BOOT_SERIAL = $("#sp-boot-serial").value.trim();
  base.GPU_ENABLED = $("#sp-gpu-on") && $("#sp-gpu-on").checked ? "1" : "0";
  if ($("#sp-gl-vendor")) base.GL_VENDOR = $("#sp-gl-vendor").value.trim();
  if ($("#sp-gl-renderer")) base.GL_RENDERER = $("#sp-gl-renderer").value.trim();
  if ($("#sp-gl-version")) base.GL_VERSION = $("#sp-gl-version").value.trim();
  base.MAC_ENABLED = $("#sp-mac-on") && $("#sp-mac-on").checked ? "1" : "0";
  if ($("#sp-mac-addr")) base.MAC_ADDR = $("#sp-mac-addr").value.trim().toLowerCase();
  base.DRM_ENABLED = $("#sp-drm-on") && $("#sp-drm-on").checked ? "1" : "0";
  if ($("#sp-drm-id")) base.DRM_ID = $("#sp-drm-id").value.trim().toLowerCase();
  base.UNAME_ENABLED = $("#sp-uname-on") && $("#sp-uname-on").checked ? "1" : "0";
  if ($("#sp-uname-rel")) base.UNAME_RELEASE = $("#sp-uname-rel").value.trim();
  if ($("#sp-bootid-mode")) base.BOOT_ID_MODE = $("#sp-bootid-mode").value || "off";
  if ($("#sp-bootid-val")) base.BOOT_ID_VALUE = $("#sp-bootid-val").value.trim().toLowerCase();
  base.CPU_SPOOF_ENABLED = $("#sp-cpu-on") && $("#sp-cpu-on").checked ? "1" : "0";
  base.CPU_PROFILE = $("#sp-cpu-profile") ? $("#sp-cpu-profile").value : (base.CPU_PROFILE || "sd8g3");
  base.MEM_STORAGE_ENABLED = $("#sp-mem-on") && $("#sp-mem-on").checked ? "1" : "0";
  base.RAM_GB = $("#sp-ram-gb") ? $("#sp-ram-gb").value : (base.RAM_GB || "16");
  base.STORAGE_GB = $("#sp-storage-gb") ? $("#sp-storage-gb").value : (base.STORAGE_GB || "512");
  base.BATTERY_ENABLED = $("#sp-bat-on") && $("#sp-bat-on").checked ? "1" : "0";
  base.BATTERY_MAH = $("#sp-battery-mah") ? $("#sp-battery-mah").value.trim() : (base.BATTERY_MAH || "5000");
  base.VULKAN_ENABLED = $("#sp-vk-on") && $("#sp-vk-on").checked ? "1" : "0";
  base.VK_DEVICE_NAME = $("#sp-vk-name") ? $("#sp-vk-name").value.trim() : (base.VK_DEVICE_NAME || "");
  base.VK_VENDOR_ID = $("#sp-vk-vid") ? $("#sp-vk-vid").value.trim() : (base.VK_VENDOR_ID || "0x5143");
  base.VK_DEVICE_ID = $("#sp-vk-did") ? $("#sp-vk-did").value.trim() : (base.VK_DEVICE_ID || "0x43050a01");
  base.SOC_NODE_ENABLED = $("#sp-soc-on") && $("#sp-soc-on").checked ? "1" : "0";
  base.SOC_FAMILY = $("#sp-soc-family") ? $("#sp-soc-family").value.trim() : "";
  base.SOC_MACHINE = $("#sp-soc-machine") ? $("#sp-soc-machine").value.trim() : "";
  base.SOC_ID_NUM = $("#sp-soc-id") ? $("#sp-soc-id").value.trim() : "";
  base.SOC_SERIAL = $("#sp-soc-serial") ? $("#sp-soc-serial").value.trim().toLowerCase() : "";
  base.CARRIER_ENABLED = $("#sp-carrier-on") && $("#sp-carrier-on").checked ? "1" : "0";
  base.CARRIER_NAME = $("#sp-carrier-name") ? $("#sp-carrier-name").value.trim() : "";
  base.CARRIER_MCCMNC = $("#sp-carrier-mccmnc") ? $("#sp-carrier-mccmnc").value.trim() : "";
  base.CARRIER_COUNTRY = $("#sp-carrier-country") ? $("#sp-carrier-country").value.trim().toLowerCase() : "";
  base.BASEBAND_VER = $("#sp-baseband") ? $("#sp-baseband").value.trim() : "";
  base.FAKE_IMEI = $("#sp-fake-imei") ? $("#sp-fake-imei").value.trim() : "";
  base.BUILD_HOST_ENABLED = $("#sp-host-on") && $("#sp-host-on").checked ? "1" : "0";
  base.SPOOF_HOST = $("#sp-host") ? $("#sp-host").value.trim() : "";
  base.SPOOF_USER = $("#sp-user") ? $("#sp-user").value.trim() : "";
  base.TZ_LOCALE_ENABLED = $("#sp-tz-on") && $("#sp-tz-on").checked ? "1" : "0";
  base.TIMEZONE_ID = $("#sp-tz") ? $("#sp-tz").value.trim() : "";
  base.LOCALE_ID = $("#sp-locale") ? $("#sp-locale").value.trim() : "";
  base.UPTIME_ENABLED = $("#sp-uptime-on") && $("#sp-uptime-on").checked ? "1" : "0";
  base.UPTIME_SEC = $("#sp-uptime") ? $("#sp-uptime").value.trim() : "14520";
  base.PURITY_ENABLED = $("#sp-purity-on") && $("#sp-purity-on").checked ? "1" : "0";
  base.HIDE_ENV_ENABLED = $("#sp-hideenv-on") && $("#sp-hideenv-on").checked ? "1" : "0";
  return base;
}

function updateSuperModeVisualState() {
  var active = hasActiveSuperPersona();
  var on = active && !!($("#sp-master-on") && $("#sp-master-on").checked);
  var usOn = on && !!($("#sp-us-on") && $("#sp-us-on").checked);
  var card = $("#super-card");
  var details = $("#super-details");
  var badge = $("#super-state-badge");
  var notice = $("#super-no-persona");
  var desc = $("#super-card-persona-desc");
  var usBlock = $("#us-mode-block");
  var usBadge = $("#sp-us-badge");
  if (card) card.classList.toggle("is-super-on", on);
  if (details) details.classList.toggle("is-dim", !on);
  if (notice) notice.classList.toggle("hidden", active);
  if (usBlock) usBlock.classList.toggle("is-us-on", usOn);
  if (usBadge) usBadge.classList.toggle("hidden", !usOn);
  if (badge) {
    badge.textContent = !active ? "当前：未激活超级新机" : (on ? "已启用 · " + (STATE.active_super_persona_name || "超级新机") + (usOn ? " · 美区" : "") : "已暂停总开关");
  }
  if (desc && active) {
    desc.textContent = "正在编辑【" + (STATE.active_super_persona_name || "超级新机") + "】参数，保存后仅对超级伪装目标列表生效。";
  }
}

function applyExtrasToUI(ex) {
  ex = ex || {};
  $("#ex-build-extra").checked = ex.BUILD_EXTRA_ENABLED === "1";
  $("#ex-device").value = ex.SPOOF_DEVICE || "";
  $("#ex-name").value = ex.SPOOF_NAME || "";
  $("#ex-board").value = ex.SPOOF_BOARD || "";
  $("#ex-platform").value = ex.SPOOF_PLATFORM || "";
  $("#ex-hardware").value = ex.SPOOF_HARDWARE || "";
  $("#ex-soc-manuf").value = ex.SPOOF_SOC_MANUF || "";
  $("#ex-soc-model").value = ex.SPOOF_SOC_MODEL || "";
  $("#ex-boot-serial").value = ex.SPOOF_BOOT_SERIAL || "";
  $("#ex-sec-patch").value = ex.SPOOF_SECURITY_PATCH || "";

  $("#ex-gpu-on").checked = ex.GPU_ENABLED === "1";
  $("#ex-gl-vendor").value = ex.GL_VENDOR || "";
  $("#ex-gl-renderer").value = ex.GL_RENDERER || "";
  $("#ex-gl-version").value = ex.GL_VERSION || "";

  $("#ex-mac-on").checked = ex.MAC_ENABLED === "1";
  $("#ex-mac-addr").value = ex.MAC_ADDR || "";

  $("#ex-drm-on").checked = ex.DRM_ENABLED === "1";
  $("#ex-drm-id").value = ex.DRM_ID || "";

  $("#ex-uname-on").checked = ex.UNAME_ENABLED === "1";
  $("#ex-uname-rel").value = ex.UNAME_RELEASE || "";
  $("#ex-uname-ver").value = ex.UNAME_VERSION || "";

  $("#ex-bootid-mode").value = ex.BOOT_ID_MODE || "off";
  $("#ex-bootid-val").value = ex.BOOT_ID_VALUE || "";
  updateBootIdRowVisibility();
}

function applySuperExtrasToUI(ex) {
  ex = ex || {};
  if ($("#sp-master-on")) $("#sp-master-on").checked = ex.SUPER_SPOOF_ENABLED === "1";
  if ($("#sp-us-on")) $("#sp-us-on").checked = ex.US_MODE_ENABLED === "1";
  if ($("#sp-us-preset")) $("#sp-us-preset").value = ex.US_PRESET || "tmobile_la";
  if ($("#sp-build-extra")) $("#sp-build-extra").checked = ex.BUILD_EXTRA_ENABLED === "1";
  if ($("#sp-device")) $("#sp-device").value = ex.SPOOF_DEVICE || "";
  if ($("#sp-name")) $("#sp-name").value = ex.SPOOF_NAME || "";
  if ($("#sp-board")) $("#sp-board").value = ex.SPOOF_BOARD || "";
  if ($("#sp-platform")) $("#sp-platform").value = ex.SPOOF_PLATFORM || "";
  if ($("#sp-hardware")) $("#sp-hardware").value = ex.SPOOF_HARDWARE || "";
  if ($("#sp-soc-manuf")) $("#sp-soc-manuf").value = ex.SPOOF_SOC_MANUF || "";
  if ($("#sp-soc-model")) $("#sp-soc-model").value = ex.SPOOF_SOC_MODEL || "";
  if ($("#sp-boot-serial")) $("#sp-boot-serial").value = ex.SPOOF_BOOT_SERIAL || "";
  if ($("#sp-gpu-on")) $("#sp-gpu-on").checked = ex.GPU_ENABLED === "1";
  if ($("#sp-gl-vendor")) $("#sp-gl-vendor").value = ex.GL_VENDOR || "";
  if ($("#sp-gl-renderer")) $("#sp-gl-renderer").value = ex.GL_RENDERER || "";
  if ($("#sp-gl-version")) $("#sp-gl-version").value = ex.GL_VERSION || "";
  if ($("#sp-mac-on")) $("#sp-mac-on").checked = ex.MAC_ENABLED === "1";
  if ($("#sp-mac-addr")) $("#sp-mac-addr").value = ex.MAC_ADDR || "";
  if ($("#sp-drm-on")) $("#sp-drm-on").checked = ex.DRM_ENABLED === "1";
  if ($("#sp-drm-id")) $("#sp-drm-id").value = ex.DRM_ID || "";
  if ($("#sp-uname-on")) $("#sp-uname-on").checked = ex.UNAME_ENABLED === "1";
  if ($("#sp-uname-rel")) $("#sp-uname-rel").value = ex.UNAME_RELEASE || "";
  if ($("#sp-bootid-mode")) $("#sp-bootid-mode").value = ex.BOOT_ID_MODE || "off";
  if ($("#sp-bootid-val")) $("#sp-bootid-val").value = ex.BOOT_ID_VALUE || "";
  if ($("#sp-cpu-on")) $("#sp-cpu-on").checked = ex.CPU_SPOOF_ENABLED === "1";
  if ($("#sp-cpu-profile")) $("#sp-cpu-profile").value = ex.CPU_PROFILE || "sd8g3";
  if ($("#sp-mem-on")) $("#sp-mem-on").checked = ex.MEM_STORAGE_ENABLED === "1";
  if ($("#sp-ram-gb")) $("#sp-ram-gb").value = ex.RAM_GB || "16";
  if ($("#sp-storage-gb")) $("#sp-storage-gb").value = ex.STORAGE_GB || "512";
  if ($("#sp-bat-on")) $("#sp-bat-on").checked = ex.BATTERY_ENABLED === "1";
  if ($("#sp-battery-mah")) $("#sp-battery-mah").value = ex.BATTERY_MAH || "5000";
  if ($("#sp-vk-on")) $("#sp-vk-on").checked = ex.VULKAN_ENABLED === "1";
  if ($("#sp-vk-name")) $("#sp-vk-name").value = ex.VK_DEVICE_NAME || ex.GL_RENDERER || "";
  if ($("#sp-vk-vid")) $("#sp-vk-vid").value = ex.VK_VENDOR_ID || "0x5143";
  if ($("#sp-vk-did")) $("#sp-vk-did").value = ex.VK_DEVICE_ID || "0x43050a01";
  if ($("#sp-soc-on")) $("#sp-soc-on").checked = ex.SOC_NODE_ENABLED === "1";
  if ($("#sp-soc-family")) $("#sp-soc-family").value = ex.SOC_FAMILY || "";
  if ($("#sp-soc-machine")) $("#sp-soc-machine").value = ex.SOC_MACHINE || "";
  if ($("#sp-soc-id")) $("#sp-soc-id").value = ex.SOC_ID_NUM || "";
  if ($("#sp-soc-serial")) $("#sp-soc-serial").value = ex.SOC_SERIAL || "";
  if ($("#sp-carrier-on")) $("#sp-carrier-on").checked = ex.CARRIER_ENABLED === "1";
  if ($("#sp-carrier-name")) $("#sp-carrier-name").value = ex.CARRIER_NAME || "中国移动";
  if ($("#sp-carrier-mccmnc")) $("#sp-carrier-mccmnc").value = ex.CARRIER_MCCMNC || "46000";
  if ($("#sp-carrier-country")) $("#sp-carrier-country").value = ex.CARRIER_COUNTRY || "cn";
  if ($("#sp-baseband")) $("#sp-baseband").value = ex.BASEBAND_VER || "";
  if ($("#sp-fake-imei")) $("#sp-fake-imei").value = ex.FAKE_IMEI || "";
  if ($("#sp-host-on")) $("#sp-host-on").checked = ex.BUILD_HOST_ENABLED === "1";
  if ($("#sp-host")) $("#sp-host").value = ex.SPOOF_HOST || "";
  if ($("#sp-user")) $("#sp-user").value = ex.SPOOF_USER || "builder";
  if ($("#sp-tz-on")) $("#sp-tz-on").checked = ex.TZ_LOCALE_ENABLED === "1";
  if ($("#sp-tz")) $("#sp-tz").value = ex.TIMEZONE_ID || "Asia/Shanghai";
  if ($("#sp-locale")) $("#sp-locale").value = ex.LOCALE_ID || "zh-CN";
  if ($("#sp-uptime-on")) $("#sp-uptime-on").checked = ex.UPTIME_ENABLED === "1";
  if ($("#sp-uptime")) $("#sp-uptime").value = ex.UPTIME_SEC || "14520";
  if ($("#sp-purity-on")) $("#sp-purity-on").checked = ex.PURITY_ENABLED === "1";
  if ($("#sp-hideenv-on")) $("#sp-hideenv-on").checked = ex.HIDE_ENV_ENABLED === "1";
  updateSuperModeVisualState();
}

function updateBootIdRowVisibility() {
  var mode = $("#ex-bootid-mode") ? $("#ex-bootid-mode").value : "off";
  var row = $("#ex-bootid-row");
  if (row) row.classList.toggle("hidden", mode !== "fixed");
}

function serializeExtras(ex) {
  var keys = Object.keys(ex);
  return keys.map(function (k) { return k + "=" + (ex[k] == null ? "" : ex[k]); }).join("\n") + "\n";
}

function scheduleExtrasSave(immediate) {
  var ind = $("#extras-saved");
  setCfgSaved(ind, "编辑中…", "is-pending");
  if (EXTRAS_SAVE_TIMER) { clearTimeout(EXTRAS_SAVE_TIMER); EXTRAS_SAVE_TIMER = null; }
  if (immediate) { saveExtrasNow(); return; }
  EXTRAS_SAVE_TIMER = setTimeout(function () {
    EXTRAS_SAVE_TIMER = null;
    saveExtrasNow();
  }, 700);
}

function scheduleSuperExtrasSave(immediate) {
  var spInd = $("#super-saved");
  if (spInd) setCfgSaved(spInd, "编辑中…", "is-pending");
  if (SUPER_EXTRAS_SAVE_TIMER) { clearTimeout(SUPER_EXTRAS_SAVE_TIMER); SUPER_EXTRAS_SAVE_TIMER = null; }
  if (immediate) { saveSuperExtrasNow(); return; }
  SUPER_EXTRAS_SAVE_TIMER = setTimeout(function () {
    SUPER_EXTRAS_SAVE_TIMER = null;
    saveSuperExtrasNow();
  }, 700);
}

async function saveExtrasNow() {
  var ind = $("#extras-saved");
  setCfgSaved(ind, "保存中…", "is-pending");
  EXTRAS_STATE = collectExtrasFromUI();
  try {
    var res = await webctlJSON("set-extras", toB64(serializeExtras(EXTRAS_STATE)), "standard");
    if (res && res.ok === false) {
      setCfgSaved(ind, "保存失败", "is-error");
      toast(res.message || "保存标准增强配置失败");
      return;
    }
    setCfgSaved(ind, "已保存", "is-ok");
    setTimeout(function () {
      if (ind && ind.classList.contains("is-ok")) setCfgSaved(ind, "", "");
    }, 2200);
  } catch (e) {
    setCfgSaved(ind, "保存失败", "is-error");
    toast("保存标准增强配置失败");
  }
}

async function saveSuperExtrasNow() {
  var spInd = $("#super-saved");
  if (!hasActiveSuperPersona()) {
    toast("请先在“设备身份 → 超级伪装模式”开启一套超级新机");
    return;
  }
  if (spInd) setCfgSaved(spInd, "保存中…", "is-pending");
  SUPER_EXTRAS_STATE = collectSuperExtrasFromUI();
  try {
    var res = await webctlJSON("set-extras", toB64(serializeExtras(SUPER_EXTRAS_STATE)), "super");
    if (res && res.ok === false) {
      if (spInd) setCfgSaved(spInd, "保存失败", "is-error");
      toast(res.message || "保存超级伪装配置失败");
      return;
    }
    if (spInd) setCfgSaved(spInd, "已保存", "is-ok");
    setTimeout(function () {
      if (spInd && spInd.classList.contains("is-ok")) setCfgSaved(spInd, "", "");
    }, 2200);
    await refresh();
  } catch (e) {
    if (spInd) setCfgSaved(spInd, "保存失败", "is-error");
    toast("保存超级伪装配置失败");
  }
}

async function loadExtrasConfig() {
  if (EXTRAS_LOADED) return;
  try {
    var r = await webctlJSON("extras-config", "standard");
    if (r && r.ok !== false && r.extras) {
      EXTRAS_STATE = r.extras;
      applyExtrasToUI(EXTRAS_STATE);
    }
  } catch (e) {}
  EXTRAS_LOADED = true;
}

async function loadSuperExtrasConfig() {
  if (SUPER_EXTRAS_LOADED) return;
  try {
    var r = await webctlJSON("extras-config", "super");
    if (r && r.ok !== false && r.extras) {
      SUPER_EXTRAS_STATE = r.extras;
      applySuperExtrasToUI(SUPER_EXTRAS_STATE);
    }
  } catch (e) {}
  updateSuperModeVisualState();
  SUPER_EXTRAS_LOADED = true;
}

async function findMatchedDevicePreset(preferSuper) {
  await loadDevices();
  var liveModel = "";
  if (preferSuper && STATE && STATE.super_summary && STATE.super_summary.model) {
    liveModel = STATE.super_summary.model;
  } else if (STATE && Array.isArray(STATE.values)) {
    STATE.values.forEach(function (v) {
      if (v.key === "ro.product.model") liveModel = v.configured || v.live || "";
    });
  }
  var matched = null;
  if (liveModel && DEVICES.length) {
    matched = DEVICES.filter(function (d) { return d.model === liveModel; })[0];
  }
  if (!matched && DEVICES.length) matched = DEVICES[0];
  return matched;
}

function applyMatchedPresetToStdFields(matched) {
  var p = matched.profile;
  if (p.device) $("#ex-device").value = p.device;
  if (p.device) $("#ex-name").value = p.device;
  if (p.board) $("#ex-board").value = p.board;
  if (p.platform) $("#ex-platform").value = p.platform;
  if (p.hardware) $("#ex-hardware").value = p.hardware;
  if (p.soc_manuf) $("#ex-soc-manuf").value = p.soc_manuf;
  if (p.soc_model) $("#ex-soc-model").value = p.soc_model;
  if (p.gl_vendor) $("#ex-gl-vendor").value = p.gl_vendor;
  if (p.gl_renderer) $("#ex-gl-renderer").value = p.gl_renderer;
  if (p.gl_version) $("#ex-gl-version").value = p.gl_version;
  if (p.uname_release) $("#ex-uname-rel").value = p.uname_release;
}

function applyMatchedPresetToSuperFields(matched) {
  var p = matched.profile;
  SUPER_EXTRAS_STATE = SUPER_EXTRAS_STATE || {};
  if ($("#sp-build-extra")) $("#sp-build-extra").checked = true;
  if (p.device && $("#sp-device")) $("#sp-device").value = p.device;
  if (p.device && $("#sp-name")) $("#sp-name").value = p.device;
  if (p.board && $("#sp-board")) $("#sp-board").value = p.board;
  if (p.platform && $("#sp-platform")) $("#sp-platform").value = p.platform;
  if (p.hardware && $("#sp-hardware")) $("#sp-hardware").value = p.hardware;
  if (p.soc_manuf && $("#sp-soc-manuf")) $("#sp-soc-manuf").value = p.soc_manuf;
  if (p.soc_model && $("#sp-soc-model")) $("#sp-soc-model").value = p.soc_model;
  if ($("#sp-boot-serial") && !$("#sp-boot-serial").value.trim()) $("#sp-boot-serial").value = genRandomSerial();
  if ($("#sp-gpu-on")) $("#sp-gpu-on").checked = true;
  if (p.gl_vendor && $("#sp-gl-vendor")) $("#sp-gl-vendor").value = p.gl_vendor;
  if (p.gl_renderer && $("#sp-gl-renderer")) $("#sp-gl-renderer").value = p.gl_renderer;
  if (p.gl_version && $("#sp-gl-version")) $("#sp-gl-version").value = p.gl_version;
  if ($("#sp-uname-on")) $("#sp-uname-on").checked = true;
  if (p.uname_release && $("#sp-uname-rel")) $("#sp-uname-rel").value = p.uname_release;
  if ($("#sp-mac-on")) $("#sp-mac-on").checked = true;
  if ($("#sp-mac-addr") && !$("#sp-mac-addr").value.trim()) $("#sp-mac-addr").value = genRandomMac();
  if ($("#sp-drm-on")) $("#sp-drm-on").checked = true;
  if ($("#sp-drm-id") && !$("#sp-drm-id").value.trim()) $("#sp-drm-id").value = randHex(64);
  if ($("#sp-bootid-mode") && ($("#sp-bootid-mode").value === "off" || !$("#sp-bootid-mode").value)) {
    $("#sp-bootid-mode").value = "fixed";
  }
  if ($("#sp-bootid-val") && !$("#sp-bootid-val").value.trim()) $("#sp-bootid-val").value = genRandomUuid();

  if (p.cpu_profile && $("#sp-cpu-profile")) $("#sp-cpu-profile").value = p.cpu_profile;
  if (p.ram_gb && $("#sp-ram-gb")) $("#sp-ram-gb").value = p.ram_gb;
  if (p.storage_gb && $("#sp-storage-gb")) $("#sp-storage-gb").value = p.storage_gb;
  if (p.battery_mah && $("#sp-battery-mah")) $("#sp-battery-mah").value = p.battery_mah;
  if (p.gl_renderer && $("#sp-vk-name")) $("#sp-vk-name").value = p.gl_renderer;
  if (p.vk_vendor_id && $("#sp-vk-vid")) $("#sp-vk-vid").value = p.vk_vendor_id;
  if (p.vk_device_id && $("#sp-vk-did")) $("#sp-vk-did").value = p.vk_device_id;
  if (p.soc_family && $("#sp-soc-family")) $("#sp-soc-family").value = p.soc_family;
  if (p.soc_machine && $("#sp-soc-machine")) $("#sp-soc-machine").value = p.soc_machine;
  if (p.soc_id && $("#sp-soc-id")) $("#sp-soc-id").value = p.soc_id;
  if (p.device && $("#sp-host")) $("#sp-host").value = p.device + "-build";
  if (p.board && $("#sp-baseband") && !$("#sp-baseband").value.trim()) {
    $("#sp-baseband").value = "MPSS.DE.5.0.c1-00214-" + p.board.toUpperCase() + "_GEN_PACK-1";
  }
}

async function autofillProfileFromCurrentDevice() {
  var matched = await findMatchedDevicePreset(false);
  if (!matched || !matched.profile) {
    toast("未找到匹配的机型硬件预设");
    return;
  }
  applyMatchedPresetToStdFields(matched);
  scheduleExtrasSave(true);
  toast("已按 " + matched.label + " 自动填充标准硬件参数");
}

async function enableSuperSpoofPreset() {
  if (!hasActiveSuperPersona()) {
    toast("请先在“设备身份 → 超级伪装模式”生成或开启一套超级新机");
    return;
  }
  var matched = await findMatchedDevicePreset(true);
  if (matched && matched.profile) applyMatchedPresetToSuperFields(matched);

  $("#sp-master-on").checked = true;
  $("#sp-cpu-on").checked = true;
  $("#sp-mem-on").checked = true;
  $("#sp-bat-on").checked = true;
  $("#sp-vk-on").checked = true;
  $("#sp-soc-on").checked = true;
  $("#sp-carrier-on").checked = true;
  $("#sp-host-on").checked = true;
  $("#sp-tz-on").checked = true;
  $("#sp-uptime-on").checked = true;
  $("#sp-purity-on").checked = true;
  $("#sp-hideenv-on").checked = true;
  if (!$("#sp-soc-serial").value.trim()) $("#sp-soc-serial").value = randHex(8);
  if (!$("#sp-fake-imei").value.trim()) $("#sp-fake-imei").value = genLuhnImei();
  updateSuperModeVisualState();
  scheduleSuperExtrasSave(true);
  toast("已重填 " + (matched ? matched.label : "当前超级新机") + " 全套硬件与新机参数，强杀超级目标应用生效");
}

async function switchToDefaultStandardMode() {
  showOverlay(true);
  try {
    var res = await webctlJSON("deactivate", "super");
    if (res && res.message) toast(res.message);
    SUPER_EXTRAS_LOADED = false;
    await refresh();
    await loadPersonas();
    updateSuperModeVisualState();
  } catch (e) {
    toast("关闭超级伪装失败");
  } finally {
    showOverlay(false);
  }
}

function rerollSuperIdentifiers() {
  if (!hasActiveSuperPersona()) {
    toast("请先在“设备身份 → 超级伪装模式”开启一套超级新机");
    return;
  }
  SUPER_EXTRAS_STATE = SUPER_EXTRAS_STATE || {};
  var newSer = genRandomSerial();
  var newMac = genRandomMac();
  var newDrm = randHex(64);
  var newBoot = genRandomUuid();
  SUPER_EXTRAS_STATE.SPOOF_BOOT_SERIAL = newSer;
  SUPER_EXTRAS_STATE.MAC_ADDR = newMac;
  SUPER_EXTRAS_STATE.DRM_ID = newDrm;
  SUPER_EXTRAS_STATE.BOOT_ID_VALUE = newBoot;
  if ($("#sp-boot-serial")) $("#sp-boot-serial").value = newSer;
  if ($("#sp-mac-addr")) $("#sp-mac-addr").value = newMac;
  if ($("#sp-drm-id")) $("#sp-drm-id").value = newDrm;
  if ($("#sp-bootid-val")) $("#sp-bootid-val").value = newBoot;
  if ($("#sp-soc-serial")) $("#sp-soc-serial").value = randHex(8);
  if ($("#sp-fake-imei")) $("#sp-fake-imei").value = genLuhnImei();
  if ($("#sp-uptime")) $("#sp-uptime").value = String(10800 + Math.floor(Math.random() * 43200));
  scheduleSuperExtrasSave(true);
  toast("已随机重生成全套超级新机硬件序列号/MAC/DRM/BootID/IMEI/SoC序列号");
}

function wireExtras() {
  var stdIds = [
    "ex-build-extra", "ex-device", "ex-name", "ex-board", "ex-platform", "ex-hardware",
    "ex-soc-manuf", "ex-soc-model", "ex-boot-serial", "ex-sec-patch",
    "ex-gpu-on", "ex-gl-vendor", "ex-gl-renderer", "ex-gl-version",
    "ex-mac-on", "ex-mac-addr", "ex-drm-on", "ex-drm-id",
    "ex-uname-on", "ex-uname-rel", "ex-uname-ver",
    "ex-bootid-mode", "ex-bootid-val"
  ];
  stdIds.forEach(function (id) {
    var el = $("#" + id);
    if (!el) return;
    var evt = (el.type === "checkbox" || el.tagName === "SELECT") ? "change" : "input";
    el.addEventListener(evt, function () {
      if (id === "ex-bootid-mode") updateBootIdRowVisibility();
      scheduleExtrasSave(el.type === "checkbox" || el.tagName === "SELECT");
    });
  });

  var spIds = [
    "sp-master-on", "sp-us-on", "sp-us-preset", "sp-build-extra", "sp-device", "sp-name", "sp-board",
    "sp-platform", "sp-hardware", "sp-soc-manuf", "sp-soc-model", "sp-boot-serial",
    "sp-gpu-on", "sp-gl-vendor", "sp-gl-renderer", "sp-gl-version",
    "sp-mac-on", "sp-mac-addr", "sp-drm-on", "sp-drm-id",
    "sp-uname-on", "sp-uname-rel", "sp-bootid-mode", "sp-bootid-val",
    "sp-cpu-on", "sp-cpu-profile",
    "sp-mem-on", "sp-ram-gb", "sp-storage-gb",
    "sp-bat-on", "sp-battery-mah", "sp-uptime-on", "sp-uptime",
    "sp-vk-on", "sp-vk-name", "sp-vk-vid", "sp-vk-did",
    "sp-soc-on", "sp-soc-family", "sp-soc-machine", "sp-soc-id", "sp-soc-serial",
    "sp-carrier-on", "sp-carrier-name", "sp-carrier-mccmnc", "sp-carrier-country",
    "sp-baseband", "sp-fake-imei",
    "sp-host-on", "sp-host", "sp-user", "sp-tz-on", "sp-tz", "sp-locale",
    "sp-purity-on", "sp-hideenv-on"
  ];
  spIds.forEach(function (id) {
    var el = $("#" + id);
    if (!el) return;
    var evt = (el.type === "checkbox" || el.tagName === "SELECT") ? "change" : "input";
    el.addEventListener(evt, function () {
      if (id === "sp-master-on" || id === "sp-us-on") updateSuperModeVisualState();
      scheduleSuperExtrasSave(el.type === "checkbox" || el.tagName === "SELECT");
    });
  });

  var spFill = $("#btn-super-autofill");
  if (spFill) spFill.addEventListener("click", enableSuperSpoofPreset);
  var spReroll = $("#btn-super-reroll");
  if (spReroll) spReroll.addEventListener("click", rerollSuperIdentifiers);
  var spDef = $("#btn-super-default");
  if (spDef) spDef.addEventListener("click", switchToDefaultStandardMode);

  var genSpImei = $("#btn-gen-sp-imei");
  if (genSpImei) genSpImei.addEventListener("click", function () {
    $("#sp-fake-imei").value = genLuhnImei();
    scheduleSuperExtrasSave(true);
  });

  var fillBtn = $("#btn-autofill-profile");
  if (fillBtn) fillBtn.addEventListener("click", autofillProfileFromCurrentDevice);

  var genMac = $("#btn-gen-mac");
  if (genMac) genMac.addEventListener("click", function () {
    $("#ex-mac-addr").value = genRandomMac();
    scheduleExtrasSave(true);
  });

  var genDrm = $("#btn-gen-drm");
  if (genDrm) genDrm.addEventListener("click", function () {
    $("#ex-drm-id").value = randHex(64);
    scheduleExtrasSave(true);
  });

  var genBoot = $("#btn-gen-bootid");
  if (genBoot) genBoot.addEventListener("click", function () {
    $("#ex-bootid-val").value = genRandomUuid();
    scheduleExtrasSave(true);
  });
}

// ---------------------------------------------------------------------------
// 日志与诊断
// ---------------------------------------------------------------------------

async function viewLogs() {
  showOverlay(true);
  try {
    var r = await webctl("logs", "300");
    var view = $("#logs-view");
    view.textContent = (r.stdout || "(暂无日志)").trim();
    view.classList.remove("hidden");
  } catch (e) {
    toast("无法读取日志");
  } finally {
    showOverlay(false);
  }
}

async function exportLogs() {
  showOverlay(true);
  try {
    var res = await webctlJSON("export-logs");
    toast(res.ok ? "已保存至 " + res.path : (res.message || "导出失败"));
  } catch (e) {
    toast("导出失败");
  } finally {
    showOverlay(false);
  }
}

async function clearLogs() {
  showOverlay(true);
  try {
    var res = await webctlJSON("clear-logs");
    toast(res.message || "日志已清空");
    var view = $("#logs-view");
    if (!view.classList.contains("hidden")) view.textContent = "";
  } catch (e) {
    toast("清空日志失败");
  } finally {
    showOverlay(false);
  }
}

async function viewDiagnostics() {
  showOverlay(true);
  try {
    var r = await webctl("diagnose");
    var view = $("#logs-view");
    view.textContent = (r.stdout || "(无诊断结果)").trim();
    view.classList.remove("hidden");
  } catch (e) {
    toast("运行诊断失败");
  } finally {
    showOverlay(false);
  }
}

// ---------------------------------------------------------------------------
// Android ID & 公用应用选择器
// ---------------------------------------------------------------------------

var AI_STATE = { enabled: false, value: "", user_id: "0", targets: [] };
var APPS = [];
var APPS_LOADED = false;
var APP_ICON_OBSERVER = null;

function validValue(v) { return /^[0-9a-f]{16}$/.test(v || ""); }

function hashHue(s) {
  var h = 0, i;
  for (i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) % 360;
  return h;
}

function bridgeSources() {
  var out = [], seen = [];
  function add(o) {
    if (!o || seen.indexOf(o) !== -1) return;
    seen.push(o);
    out.push(o);
  }
  add(window);
  if (typeof ksu !== "undefined") add(ksu);
  add(window.ksu);
  add(window.kernelsu);
  add(window.KernelSU);
  add(window.apatch);
  return out;
}

function parseMaybeJSON(raw) {
  if (raw == null) return null;
  if (typeof raw === "string") {
    try { return JSON.parse(raw); } catch (e) { return null; }
  }
  return raw;
}

async function callBridge(obj, name, args) {
  if (!obj || typeof obj[name] !== "function") return null;
  try {
    var raw = obj[name].apply(obj, args || []);
    if (raw && typeof raw.then === "function") raw = await raw;
    return parseMaybeJSON(raw);
  } catch (e) { return null; }
}

function normalizePackageList(raw) {
  if (!Array.isArray(raw)) return null;
  var pkgs = raw.map(function (item) {
    if (typeof item === "string") return item;
    return item && (item.packageName || item.pkg || item.name);
  }).filter(function (pkg) { return typeof pkg === "string" && pkg.length > 0; });
  return pkgs.length ? pkgs : null;
}

async function nativeListPackages(type) {
  var sources = bridgeSources();
  var perType = { all: "listAllPackages", user: "listUserPackages", system: "listSystemPackages" }[type];
  for (var i = 0; i < sources.length; i++) {
    var raw = perType ? await callBridge(sources[i], perType) : null;
    var pkgs = normalizePackageList(raw);
    if (pkgs) return pkgs;

    raw = await callBridge(sources[i], "listPackages", [type]);
    pkgs = normalizePackageList(raw);
    if (pkgs) return pkgs;
  }
  return null;
}

async function nativeGetPackagesInfo(pkgs) {
  var sources = bridgeSources();
  for (var i = 0; i < sources.length; i++) {
    var source = sources[i];
    var raw, directKsu = source === window.ksu || (typeof ksu !== "undefined" && source === ksu);
    if (directKsu) {
      raw = await callBridge(source, "getPackagesInfo", [JSON.stringify(pkgs)]);
      if (hasPackageInfo(raw)) return raw;
      raw = await callBridge(source, "getPackagesInfo", [pkgs]);
      if (hasPackageInfo(raw)) return raw;
    } else {
      raw = await callBridge(source, "getPackagesInfo", [pkgs]);
      if (hasPackageInfo(raw)) return raw;
      raw = await callBridge(source, "getPackagesInfo", [JSON.stringify(pkgs)]);
      if (hasPackageInfo(raw)) return raw;
    }
  }
  return null;
}

function hasPackageInfo(infos) {
  if (Array.isArray(infos)) return infos.length > 0;
  return !!infos && typeof infos === "object" && Object.keys(infos).length > 0;
}

function infoForPackage(infos, pkg, index) {
  if (!infos) return null;
  if (Array.isArray(infos)) return infos[index] || null;
  if (typeof infos === "object") return infos[pkg] || null;
  return null;
}

function normalizeApp(pkg, info, fallbackSystem) {
  info = info || {};
  var label = info.appLabel || info.appName || info.label || info.name || pkg;
  var system = info.isSystem != null ? !!info.isSystem :
               info.system != null ? !!info.system : !!fallbackSystem;
  return { pkg: pkg, label: String(label || pkg), system: system };
}

async function loadApps() {
  var pkgs = await nativeListPackages("all");
  if (pkgs && pkgs.length) {
    var infos = await nativeGetPackagesInfo(pkgs);
    APPS = pkgs.map(function (pkg, i) {
      return normalizeApp(pkg, infoForPackage(infos, pkg, i), false);
    });
  } else {
    var r = await webctlJSON("list-apps", "all");
    var arr = (r && r.apps) || [];
    APPS = arr.map(function (a) {
      return normalizeApp(a.pkg, { appLabel: a.label }, !!a.system);
    });
  }
  APPS = APPS.filter(function (app) { return app && app.pkg; });
  APPS.sort(function (a, b) {
    var x = a.label.toLowerCase(), y = b.label.toLowerCase();
    return x < y ? -1 : x > y ? 1 : 0;
  });
  APPS_LOADED = true;
}

function updatePickerSafeArea() {
  document.documentElement.style.setProperty("--picker-top-fallback", "24px");
}

function currentPickerTargets() {
  if (PICKER_MODE === "scope") return SCOPE_STATE.targets;
  if (PICKER_MODE === "super_scope") return SCOPE_STATE.superTargets;
  return AI_STATE.targets;
}

function targetCountText(n) { return "已选 " + n + " 个应用"; }

function updateTargetCount() {
  var card = $("#ai-target-count");
  if (card) card.textContent = targetCountText(AI_STATE.targets.length);
  var scCard = $("#scope-target-count");
  if (scCard) scCard.textContent = targetCountText(SCOPE_STATE.targets.length);
  var spCard = $("#super-scope-target-count");
  if (spCard) spCard.textContent = targetCountText(SCOPE_STATE.superTargets.length);
  var pStd = $("#personas-std-scope-count");
  if (pStd) pStd.textContent = targetCountText(SCOPE_STATE.targets.length);
  var pSup = $("#personas-super-scope-count");
  if (pSup) pSup.textContent = targetCountText(SCOPE_STATE.superTargets.length);
  updatePickerCount();
}

function updatePickerCount() {
  var el = $("#picker-count");
  if (el) el.textContent = targetCountText(currentPickerTargets().length);
}

function toggleTarget(pkg, on) {
  var arr = currentPickerTargets();
  var i = arr.indexOf(pkg);
  if (on && i === -1) arr.push(pkg);
  else if (!on && i !== -1) arr.splice(i, 1);
  updateTargetCount();
}

function loadAppIcon(img, pkg) {
  if (!img || !pkg || img.dataset.iconLoaded === "1") return;
  img.dataset.iconLoaded = "1";
  img.src = "ksu://icon/" + pkg;
  setTimeout(function () {
    if (!img.parentNode || img.classList.contains("is-loaded")) return;
    if (img.complete && img.naturalWidth > 0) img.classList.add("is-loaded");
    else img.remove();
  }, 3000);
}

function observeAppIcon(img, pkg) {
  if (!("IntersectionObserver" in window)) {
    loadAppIcon(img, pkg);
    return;
  }
  if (!APP_ICON_OBSERVER) {
    APP_ICON_OBSERVER = new IntersectionObserver(function (entries, observer) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        observer.unobserve(entry.target);
        loadAppIcon(entry.target, entry.target.dataset.pkg);
      });
    }, { root: $("#picker-list"), rootMargin: "240px 0px" });
  }
  img.dataset.pkg = pkg;
  APP_ICON_OBSERVER.observe(img);
}

function makeAppRow(app) {
  var row = document.createElement("label");
  row.className = "app-row";
  row.dataset.pkg = app.pkg;
  row.dataset.label = app.label.toLowerCase();
  row.dataset.system = app.system ? "1" : "0";

  var ic = document.createElement("div");
  ic.className = "app-ic";

  var fb = document.createElement("div");
  fb.className = "app-ic-fallback";
  fb.textContent = (app.label.charAt(0) || app.pkg.charAt(0) || "?").toUpperCase();
  fb.style.background = "hsl(" + hashHue(app.pkg) + ", 52%, 52%)";
  var img = document.createElement("img");
  img.className = "app-ic-img";
  img.alt = "";
  img.decoding = "async";
  img.addEventListener("load", function () { img.classList.add("is-loaded"); });
  img.addEventListener("error", function () { img.remove(); });
  ic.appendChild(fb);
  ic.appendChild(img);
  observeAppIcon(img, app.pkg);

  var txt = document.createElement("div");
  txt.className = "app-txt";
  var t = document.createElement("div");
  t.className = "app-title";
  t.textContent = app.label;
  var p = document.createElement("div");
  p.className = "app-pkg";
  p.textContent = app.pkg;
  txt.appendChild(t);
  txt.appendChild(p);

  var cb = document.createElement("input");
  cb.type = "checkbox";
  cb.className = "app-check";
  cb.checked = currentPickerTargets().indexOf(app.pkg) !== -1;
  cb.addEventListener("change", function () { toggleTarget(app.pkg, cb.checked); filterPicker(); });

  row.appendChild(ic);
  row.appendChild(txt);
  row.appendChild(cb);
  return row;
}

function renderPickerList() {
  var list = $("#picker-list");
  if (APP_ICON_OBSERVER) APP_ICON_OBSERVER.disconnect();
  APP_ICON_OBSERVER = null;
  list.innerHTML = "";
  var frag = document.createDocumentFragment();
  APPS.forEach(function (app) { frag.appendChild(makeAppRow(app)); });
  list.appendChild(frag);
  filterPicker();
}

function syncPickerChecks() {
  var targets = currentPickerTargets();
  $all(".app-row", $("#picker-list")).forEach(function (row) {
    var cb = row.querySelector(".app-check");
    if (cb) cb.checked = targets.indexOf(row.dataset.pkg) !== -1;
  });
}

function filterPicker() {
  var q = ($("#picker-search-input").value || "").trim().toLowerCase();
  var showSys = $("#picker-show-system").checked;
  var rows = $all(".app-row", $("#picker-list"));
  var targets = currentPickerTargets();
  var shown = 0;
  rows.forEach(function (row) {
    var selected = targets.indexOf(row.dataset.pkg) !== -1;
    var sysOk = showSys || row.dataset.system !== "1" || selected;
    var hay = row.dataset.label + " " + row.dataset.pkg;
    var match = sysOk && (!q || hay.indexOf(q) !== -1);
    row.classList.toggle("hidden", !match);
    if (match) shown++;
  });
  var status = $("#picker-status");
  if (!APPS.length) { status.textContent = "未获取到任何应用。"; status.classList.remove("hidden"); }
  else if (!shown) { status.textContent = "没有匹配搜索条件的应用。"; status.classList.remove("hidden"); }
  else status.classList.add("hidden");
}

async function openPicker(mode) {
  if (mode === "scope" || mode === "super_scope") {
    PICKER_MODE = mode;
    if (!SCOPE_LOADED) await loadScopeConfig();
  } else {
    PICKER_MODE = "android_id";
  }
  var titleEl = $("#picker-title");
  if (titleEl) {
    if (PICKER_MODE === "scope") titleEl.textContent = "选择默认标准模式目标应用";
    else if (PICKER_MODE === "super_scope") titleEl.textContent = "选择超级伪装目标应用（独立清单）";
    else titleEl.textContent = "选择 Android ID 目标应用";
  }

  var picker = $("#app-picker");
  updatePickerSafeArea();
  picker.classList.remove("hidden");
  picker.setAttribute("aria-hidden", "false");
  document.body.classList.add("picker-open");
  updatePickerCount();

  if (!APPS_LOADED) {
    $("#picker-status").textContent = "正在加载应用列表…";
    $("#picker-status").classList.remove("hidden");
    showOverlay(true);
    try {
      await loadApps();
      renderPickerList();
    } catch (e) {
      $("#picker-status").textContent = "加载应用列表失败。";
      uiLog("app list load failed: " + (e && e.message ? e.message : String(e)));
    } finally {
      showOverlay(false);
    }
  } else {
    syncPickerChecks();
    filterPicker();
  }
}

function closePicker() {
  var picker = $("#app-picker");
  picker.classList.add("hidden");
  picker.setAttribute("aria-hidden", "true");
  document.body.classList.remove("picker-open");
  updateTargetCount();
  if (PICKER_MODE === "scope") saveScopeNow();
  else if (PICKER_MODE === "super_scope") saveSuperScopeNow();
  else persistSelection();
}

function syncValueFromField() {
  AI_STATE.value = ($("#ai-value").value || "").trim().toLowerCase();
}

function validateValueField() {
  var ok = validValue(AI_STATE.value);
  var input = $("#ai-value");
  var hint = $("#ai-value-hint");
  input.classList.toggle("invalid", !ok && (AI_STATE.value || "").length > 0);
  if (!AI_STATE.value) { hint.textContent = "需为 16 位小写十六进制字符（0–9，a–f）。"; hint.className = "ai-hint"; }
  else if (ok) { hint.textContent = "Android ID 格式有效。"; hint.className = "ai-hint ai-hint-ok"; }
  else { hint.textContent = "必须恰好为 16 位十六进制字符（0–9，a–f）。"; hint.className = "ai-hint ai-hint-bad"; }
}

function buildAndroidPayload(enabled) {
  var lines = [];
  lines.push("ENABLED=" + (enabled ? "1" : "0"));
  lines.push("VALUE=" + (AI_STATE.value || ""));
  lines.push("USER=" + (AI_STATE.user_id || "0"));
  AI_STATE.targets.forEach(function (p) { lines.push("PKG=" + p); });
  return lines.join("\n") + "\n";
}

var AI_SAVE_TIMER = null;

async function aiSaveNow() {
  syncValueFromField();
  if (!validValue(AI_STATE.value)) { validateValueField(); return; }
  try {
    var res = await webctlJSON("set-android-id", toB64(buildAndroidPayload(AI_STATE.enabled)));
    if (res && res.ok === false) { toast(res.message || "保存 Android ID 失败"); return; }
    markRebootUI();
  } catch (e) { uiLog("android-id save threw: " + (e && e.message ? e.message : String(e))); }
}

function aiAutoSave(immediate) {
  if (AI_SAVE_TIMER) { clearTimeout(AI_SAVE_TIMER); AI_SAVE_TIMER = null; }
  if (immediate) { aiSaveNow(); return; }
  AI_SAVE_TIMER = setTimeout(function () { AI_SAVE_TIMER = null; aiSaveNow(); }, 600);
}

function persistSelection() { aiAutoSave(true); }

function setAiEnabledUI(on) {
  AI_STATE.enabled = !!on;
  var box = $("#ai-enabled");
  if (box) box.checked = !!on;
  var card = $("#android-id-card");
  if (card) card.classList.toggle("ai-on", !!on);
}

function onAiEnabledToggle(on) {
  if (on) {
    syncValueFromField();
    if (!validValue(AI_STATE.value)) {
      AI_STATE.value = genHex16();
      $("#ai-value").value = AI_STATE.value;
      validateValueField();
    }
    if (!AI_STATE.targets.length) toast("请先选择 Android ID 目标应用（重启生效）。");
  }
  setAiEnabledUI(on);
  aiAutoSave(true);
}

async function applyAndroidIdNow() {
  showOverlay(true);
  try {
    await aiSaveNow();
    var res = await webctlJSON("apply-android-id");
    if (res && res.message) toast(res.message, { reboot: !!res.reboot_required });
  } catch (e) {
    toast("写入 SSAID 失败");
  } finally {
    showOverlay(false);
  }
}

async function restoreAndroidIdNow() {
  showOverlay(true);
  try {
    var res = await webctlJSON("restore-android-id");
    if (res && res.message) toast(res.message, { reboot: !!res.reboot_required });
    ANDROID_ID_LOADED = false;
    await loadAndroidIdConfig();
  } catch (e) {
    toast("恢复原机 Android ID 失败");
  } finally {
    showOverlay(false);
  }
}

async function loadAndroidIdConfig() {
  if (ANDROID_ID_LOADED) return;
  try {
    var c = await webctlJSON("android-id-config");
    if (c && c.ok !== false && !c._parseError) {
      AI_STATE.enabled = !!c.enabled;
      AI_STATE.user_id = c.user_id || "0";
      AI_STATE.targets = Array.isArray(c.targets) ? c.targets.slice() : [];
      AI_STATE.value = c.value || "";
    }
  } catch (e) {}
  if (!validValue(AI_STATE.value)) AI_STATE.value = genHex16();
  $("#ai-value").value = AI_STATE.value;
  validateValueField();
  setAiEnabledUI(AI_STATE.enabled);
  updateTargetCount();
  ANDROID_ID_LOADED = true;
}

function wireAndroidIdAndScope() {
  $("#btn-open-apps").addEventListener("click", function () { openPicker("android_id"); });
  var scopeBtn = $("#btn-open-scope-apps");
  if (scopeBtn) scopeBtn.addEventListener("click", function () { openPicker("scope"); });
  var superScopeBtn = $("#btn-open-super-scope-apps");
  if (superScopeBtn) superScopeBtn.addEventListener("click", function () { openPicker("super_scope"); });
  var pStdScopeBtn = $("#btn-personas-std-scope");
  if (pStdScopeBtn) pStdScopeBtn.addEventListener("click", function () { openPicker("scope"); });
  var pSupScopeBtn = $("#btn-personas-super-scope");
  if (pSupScopeBtn) pSupScopeBtn.addEventListener("click", function () { openPicker("super_scope"); });

  var perRadio = $("#mode-per-app");
  var glbRadio = $("#mode-global");
  if (perRadio) perRadio.addEventListener("change", function () {
    if (perRadio.checked) { SCOPE_STATE.mode = "per_app"; saveScopeNow(); }
  });
  if (glbRadio) glbRadio.addEventListener("change", function () {
    if (glbRadio.checked) { SCOPE_STATE.mode = "global"; saveScopeNow(); }
  });

  var fsBtn = $("#btn-force-stop-targets");
  if (fsBtn) fsBtn.addEventListener("click", function () { forceStopTargets("standard"); });
  var fsSupBtn = $("#btn-force-stop-super-targets");
  if (fsSupBtn) fsSupBtn.addEventListener("click", function () { forceStopTargets("super"); });
  var dashFsBtn = $("#btn-dash-forcestop");
  if (dashFsBtn) dashFsBtn.addEventListener("click", function () { forceStopTargets("standard"); });
  var dashSupFsBtn = $("#btn-dash-super-forcestop");
  if (dashSupFsBtn) dashSupFsBtn.addEventListener("click", function () { forceStopTargets("super"); });

  var syncBtn = $("#btn-sync-ai-targets");
  if (syncBtn) syncBtn.addEventListener("click", syncAiTargets);

  var applyAiBtn = $("#btn-apply-ai-now");
  if (applyAiBtn) applyAiBtn.addEventListener("click", applyAndroidIdNow);
  var restAiBtn = $("#btn-restore-ai");
  if (restAiBtn) restAiBtn.addEventListener("click", restoreAndroidIdNow);

  $("#picker-back").addEventListener("click", closePicker);
  $("#picker-done").addEventListener("click", closePicker);
  $("#picker-search-input").addEventListener("input", filterPicker);
  $("#picker-show-system").addEventListener("change", filterPicker);
  $("#ai-generate").addEventListener("click", function () {
    AI_STATE.value = genHex16();
    $("#ai-value").value = AI_STATE.value;
    validateValueField();
    aiAutoSave(true);
  });
  $("#ai-value").addEventListener("input", function () { syncValueFromField(); validateValueField(); aiAutoSave(); });
  var aiEnabled = $("#ai-enabled");
  if (aiEnabled) aiEnabled.addEventListener("change", function () { onAiEnabledToggle(aiEnabled.checked); });
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && !$("#app-picker").classList.contains("hidden")) closePicker();
  });
  window.addEventListener("resize", function () {
    if (!$("#app-picker").classList.contains("hidden")) updatePickerSafeArea();
  });
  if (window.visualViewport) {
    window.visualViewport.addEventListener("resize", function () {
      if (!$("#app-picker").classList.contains("hidden")) updatePickerSafeArea();
    });
  }
}

// ---------------------------------------------------------------------------
// 设备身份管理 (Personas)
// ---------------------------------------------------------------------------

var PERSONAS = [];

async function loadPersonas() {
  var stdListEl = $("#personas-list-standard");
  var supListEl = $("#personas-list-super");
  showOverlay(true);
  try {
    var data = await webctlJSON("personas");
    if (data && data.ok !== false && Array.isArray(data.personas)) {
      PERSONAS = data.personas;
      var pStd = $("#personas-std-scope-count");
      if (pStd && typeof data.std_targets !== "undefined") pStd.textContent = targetCountText(Number(data.std_targets) || 0);
      var pSup = $("#personas-super-scope-count");
      if (pSup && typeof data.super_targets !== "undefined") pSup.textContent = targetCountText(Number(data.super_targets) || 0);
      renderPersonas();
    } else {
      if (stdListEl) stdListEl.innerHTML = "";
      if (supListEl) supListEl.innerHTML = "";
      toast(data && data.message ? data.message : "加载身份列表失败");
    }
  } catch (e) {
    toast("加载身份列表失败");
    uiLog("personas load threw: " + (e && e.message ? e.message : String(e)));
  } finally {
    showOverlay(false);
  }
}

function personaSubtitle(p) {
  var bits = [];
  var dev = [p.brand, p.model].filter(Boolean).join(" ");
  if (dev) bits.push(dev);
  if (p.mode === "super") {
    if (p.cpu_profile) bits.push(p.cpu_profile);
    if (p.ram_gb && p.storage_gb) bits.push(p.ram_gb + "GB/" + p.storage_gb + "GB");
    if (p.gl_renderer) bits.push(p.gl_renderer);
    bits.push("超级目标(" + (p.scope_targets || 0) + ")");
  } else {
    if (p.scope_mode === "per_app") {
      bits.push("标准按应用(" + (p.scope_targets || 0) + ")");
    } else {
      bits.push("全局");
    }
    if (p.android_id_enabled && Number(p.android_id_targets) > 0) {
      bits.push("Android ID × " + p.android_id_targets);
    }
  }
  return bits.join(" · ");
}

function renderPersonas() {
  var stdListEl = $("#personas-list-standard");
  var stdEmptyEl = $("#personas-empty-standard");
  var supListEl = $("#personas-list-super");
  var supEmptyEl = $("#personas-empty-super");
  var stdList = PERSONAS.filter(function (p) { return p.mode !== "super"; });
  var supList = PERSONAS.filter(function (p) { return p.mode === "super"; });

  if (stdListEl) {
    stdListEl.innerHTML = "";
    if (!stdList.length) {
      if (stdEmptyEl) stdEmptyEl.classList.remove("hidden");
    } else {
      if (stdEmptyEl) stdEmptyEl.classList.add("hidden");
      stdList.forEach(function (p) { stdListEl.appendChild(makePersonaRow(p)); });
    }
  }
  if (supListEl) {
    supListEl.innerHTML = "";
    if (!supList.length) {
      if (supEmptyEl) supEmptyEl.classList.remove("hidden");
    } else {
      if (supEmptyEl) supEmptyEl.classList.add("hidden");
      supList.forEach(function (p) { supListEl.appendChild(makePersonaRow(p)); });
    }
  }
}

function makePersonaRow(p) {
  var isSuper = (p.mode === "super");
  var row = document.createElement("div");
  row.className = "persona-row" + (isSuper ? " is-super" : "") + (p.active ? " is-active" : "");
  row.dataset.id = p.id;

  var main = document.createElement("div");
  main.className = "persona-main";

  var name = document.createElement("input");
  name.className = "persona-name";
  name.type = "text";
  name.value = p.name || "设备身份";
  name.spellcheck = false;
  name.autocapitalize = "words";
  name.setAttribute("aria-label", "身份名称");
  name.addEventListener("change", function () { commitPersonaRename(p, name); });
  name.addEventListener("keydown", function (e) { if (e.key === "Enter") name.blur(); });
  main.appendChild(name);

  var sub = document.createElement("div");
  sub.className = "persona-sub";
  if (isSuper) {
    var tag = document.createElement("span");
    tag.className = "persona-mode-tag";
    tag.textContent = "超级新机";
    sub.appendChild(tag);
  }
  sub.appendChild(document.createTextNode(personaSubtitle(p) || "点击上方名称可修改 · 右侧开关启用"));
  main.appendChild(sub);

  var actions = document.createElement("div");
  actions.className = "persona-actions";

  var sw = makeSwitch(p.active, function (on) { setPersonaActive(p.id, on, isSuper ? "super" : "standard"); });
  sw.classList.add("persona-switch");
  actions.appendChild(sw);

  var del = document.createElement("button");
  del.className = "persona-del";
  del.type = "button";
  del.setAttribute("aria-label", "删除身份");
  del.innerHTML = "&#10005;";
  var armed = false, armTimer = null;
  del.addEventListener("click", function () {
    if (!armed) {
      armed = true;
      del.classList.add("armed");
      del.textContent = "确认删除?";
      armTimer = setTimeout(function () {
        armed = false; del.classList.remove("armed"); del.innerHTML = "&#10005;";
      }, 2500);
      return;
    }
    if (armTimer) clearTimeout(armTimer);
    deletePersona(p);
  });
  actions.appendChild(del);

  row.appendChild(main);
  row.appendChild(actions);
  return row;
}

async function commitPersonaRename(p, inputEl) {
  var newName = (inputEl.value || "").trim();
  if (!newName || newName === p.name) { inputEl.value = p.name || "设备身份"; return; }
  try {
    var res = await webctlJSON("persona-rename", p.id, "b64:" + toB64(newName));
    if (res && res.ok === false) { toast(res.message || "重命名失败"); inputEl.value = p.name; return; }
    p.name = newName;
    if (p.active && STATE) {
      if (p.mode === "super") STATE.active_super_persona_name = newName;
      else STATE.active_persona_name = newName;
      renderStatus();
    }
  } catch (e) { toast("重命名失败"); inputEl.value = p.name; }
}

async function setPersonaActive(id, on, mode) {
  showOverlay(true);
  try {
    var res = on ? await webctlJSON("persona-activate", id) : await webctlJSON("deactivate", mode || "standard");
    if (res && res.ok === false) { toast(res.message || "操作失败"); await loadPersonas(); return; }
    if (res && res.message) toast(res.message, { reboot: !!res.reboot_required });
    resetConfigEditors();
    await refresh();
    await loadPersonas();
  } catch (e) {
    toast("操作失败");
  } finally {
    showOverlay(false);
  }
}

async function generatePersona(mode) {
  var pmode = mode === "super" ? "super" : "standard";
  var sel = $(pmode === "super" ? "#super-device-select" : "#device-select");
  var device = sel && !sel.classList.contains("hidden") ? sel.value : "";
  showOverlay(true);
  try {
    var res = await webctlJSON("generate-persona", "", device, pmode);
    if (res && res.ok === false) { toast(res.message || "生成失败"); return; }
    if (res && res.message) toast(res.message, { reboot: !!res.reboot_required });
    resetConfigEditors();
    await refresh();
    await loadPersonas();
  } catch (e) {
    toast("生成身份失败");
    uiLog("generate persona threw: " + (e && e.message ? e.message : String(e)));
  } finally {
    showOverlay(false);
  }
}

async function deletePersona(p) {
  showOverlay(true);
  try {
    var res = await webctlJSON("persona-delete", p.id);
    if (res && res.ok === false) { toast(res.message || "删除失败"); return; }
    if (res && res.message) toast(res.message, { reboot: !!res.reboot_required });
    if (p.active) { resetConfigEditors(); await refresh(); }
    await loadPersonas();
  } catch (e) {
    toast("删除失败");
  } finally {
    showOverlay(false);
  }
}

var DEVICES = [];
var DEVICES_LOADED = false;
var PHONE_ANDROID = "";

async function loadDevices() {
  if (DEVICES_LOADED) return;
  try {
    var data = await webctlJSON("devices");
    if (data && data.ok !== false && Array.isArray(data.devices) && data.devices.length) {
      DEVICES = data.devices;
      PHONE_ANDROID = data.android || "";
      DEVICES_LOADED = true;
      renderDevices();
    }
  } catch (e) {
    uiLog("devices load threw: " + (e && e.message ? e.message : String(e)));
  }
}

function renderDevices() {
  var sel = $("#device-select");
  if (sel) {
    sel.innerHTML = "";
    DEVICES.forEach(function (d) {
      var opt = document.createElement("option");
      opt.value = d.key;
      opt.textContent = d.label + " · Android " + d.android + (d.match ? "" : " ⚠");
      sel.appendChild(opt);
    });
    var rnd = document.createElement("option");
    rnd.value = "random";
    rnd.textContent = "随机机型模板";
    sel.appendChild(rnd);
    sel.classList.remove("hidden");
  }
  var ssel = $("#super-device-select");
  if (ssel) {
    ssel.innerHTML = "";
    DEVICES.forEach(function (d) {
      var opt = document.createElement("option");
      opt.value = d.key;
      var hw = d.profile && d.profile.soc_model ? (" · " + d.profile.soc_model + " · " + (d.profile.ram_gb || "16") + "G/" + (d.profile.storage_gb || "512") + "G") : "";
      opt.textContent = d.label + hw + " · Android " + d.android;
      if (d.key === "pixel_11_pro") opt.selected = true;
      ssel.appendChild(opt);
    });
    var srnd = document.createElement("option");
    srnd.value = "random";
    srnd.textContent = "随机超级新机模板";
    ssel.appendChild(srnd);
    ssel.classList.remove("hidden");
  }
  updateDeviceNote();
}

function updateDeviceNote() {
  [["#device-select", "#device-note"], ["#super-device-select", "#super-device-note"]].forEach(function (pair) {
    var sel = $(pair[0]);
    var note = $(pair[1]);
    if (!sel || !note) return;
    var d = DEVICES.filter(function (x) { return x.key === sel.value; })[0];
    if (d && !d.match) {
      note.textContent = d.label + " 暂无 Android " + (PHONE_ANDROID || "?") +
        " 指纹，将自动选用其 Android " + d.android + " 构建信息。";
      note.classList.remove("hidden");
    } else {
      note.classList.add("hidden");
    }
  });
}

async function exportPersonas() {
  showOverlay(true);
  try {
    var res = await webctlJSON("persona-export", "all");
    toast(res.message || (res.ok === false ? "导出失败" : "导出成功"));
  } catch (e) {
    toast("导出失败");
    uiLog("persona export threw: " + (e && e.message ? e.message : String(e)));
  } finally {
    showOverlay(false);
  }
}

async function toggleImportCard() {
  var card = $("#import-card");
  if (!card) return;
  if (!card.classList.contains("hidden")) { card.classList.add("hidden"); return; }
  await loadImportFiles();
  card.classList.remove("hidden");
}

async function loadImportFiles() {
  showOverlay(true);
  try {
    var data = await webctlJSON("persona-imports");
    if (data && data.ok === false) toast(data.message || "无法列出导入文件");
    renderImportFiles(data && Array.isArray(data.files) ? data.files : []);
  } catch (e) {
    toast("无法列出导入文件");
    renderImportFiles([]);
  } finally {
    showOverlay(false);
  }
}

function importFolder(path) {
  return String(path || "").replace(/^\/storage\/emulated\/0\//, "").replace(/\/[^\/]*$/, "");
}

function renderImportFiles(files) {
  var list = $("#import-list");
  var empty = $("#import-empty");
  if (!list || !empty) return;
  list.innerHTML = "";
  empty.classList.toggle("hidden", files.length > 0);
  files.forEach(function (f) {
    var row = document.createElement("div");
    row.className = "import-row";

    var txt = document.createElement("div");
    txt.className = "import-txt";
    var file = document.createElement("div");
    file.className = "import-file";
    file.textContent = f.file;
    var dir = document.createElement("div");
    dir.className = "import-dir";
    dir.textContent = importFolder(f.path);
    txt.appendChild(file);
    txt.appendChild(dir);

    var btn = document.createElement("button");
    btn.className = "btn import-btn";
    btn.type = "button";
    btn.textContent = "导入";
    btn.addEventListener("click", function () { importPersona(f.path); });

    row.appendChild(txt);
    row.appendChild(btn);
    list.appendChild(row);
  });
}

async function importPersona(path) {
  showOverlay(true);
  try {
    var res = await webctlJSON("persona-import", path);
    toast(res.message || (res.ok === false ? "导入失败" : "已导入"));
    if (res.ok !== false && !res.skipped) await loadPersonas();
  } catch (e) {
    toast("导入失败");
    uiLog("persona import threw: " + (e && e.message ? e.message : String(e)));
  } finally {
    showOverlay(false);
  }
}

function switchTab(tab) {
  $all(".tab").forEach(function (b) { b.classList.toggle("is-active", b.dataset.tab === tab); });
  $all(".tab-panel").forEach(function (p) { p.classList.toggle("is-active", p.id === "panel-" + tab); });
  if (!hasBridge()) return;
  if (tab === "personas") { loadPersonas(); loadDevices(); loadScopeConfig(true); }
  if (tab === "config") showConfigTab();
}

function showConfigTab() {
  var notice = $("#config-no-persona");
  var body = $("#config-body");
  if (!hasActiveAnyPersona()) {
    if (notice) notice.classList.remove("hidden");
    if (body) body.classList.add("hidden");
    return;
  }
  if (notice) notice.classList.add("hidden");
  if (body) body.classList.remove("hidden");
  var exCard = $("#extras-card");
  if (exCard) exCard.classList.toggle("hidden", !hasActivePersona());
  var aiCard = $("#android-id-card");
  if (aiCard) aiCard.classList.toggle("hidden", !hasActivePersona());
  var editorsWrap = $("#config-editors-wrap");
  if (editorsWrap) editorsWrap.classList.toggle("hidden", !hasActiveAnyPersona());
  loadScopeConfig();
  if (hasActivePersona()) {
    loadExtrasConfig();
    loadAndroidIdConfig();
  }
  loadSuperExtrasConfig();
  loadConfigEditors();
}

function wire() {
  $("#tabs").addEventListener("click", function (e) {
    var btn = e.target.closest(".tab");
    if (btn) switchTab(btn.dataset.tab);
  });

  var cfgStdBtn = $("#btn-cfg-mode-std");
  var cfgSupBtn = $("#btn-cfg-mode-super");
  if (cfgStdBtn) cfgStdBtn.addEventListener("click", function () {
    if (!hasActivePersona() || EDIT_CONFIG_MODE === "standard") return;
    EDIT_CONFIG_MODE = "standard";
    CONFIGS_LOADED = false;
    loadConfigEditors();
  });
  if (cfgSupBtn) cfgSupBtn.addEventListener("click", function () {
    if (!hasActiveSuperPersona() || EDIT_CONFIG_MODE === "super") return;
    EDIT_CONFIG_MODE = "super";
    CONFIGS_LOADED = false;
    loadConfigEditors();
  });

  document.body.addEventListener("click", function (e) {
    var btn = e.target.closest("[data-action]");
    if (!btn) return;
    var action = btn.dataset.action;
    if (action === "reboot") { doReboot(); return; }
    runAction(action);
  });

  document.body.addEventListener("click", function (e) {
    var t = e.target.closest("[data-go-tab]");
    if (t) switchTab(t.dataset.goTab);
  });

  document.body.addEventListener("click", function (e) {
    var link = e.target.closest("[data-external-url]");
    if (!link || !hasBridge()) return;
    e.preventDefault();
    openExternalUrl(link.dataset.externalUrl || link.href);
  });

  var gen = $("#btn-generate-persona");
  if (gen) gen.addEventListener("click", function () { generatePersona("standard"); });
  var genSup = $("#btn-generate-super-persona");
  if (genSup) genSup.addEventListener("click", function () { generatePersona("super"); });
  var devSel = $("#device-select");
  if (devSel) devSel.addEventListener("change", updateDeviceNote);
  var supDevSel = $("#super-device-select");
  if (supDevSel) supDevSel.addEventListener("change", updateDeviceNote);
  var imp = $("#btn-import-personas");
  if (imp) imp.addEventListener("click", toggleImportCard);
  var exp = $("#btn-export-personas");
  if (exp) exp.addEventListener("click", exportPersonas);

  var retry = $("#btn-retry-status");
  if (retry) retry.addEventListener("click", refresh);

  $("#btn-view-logs").addEventListener("click", viewLogs);
  $("#btn-export-logs").addEventListener("click", exportLogs);
  $("#btn-clear-logs").addEventListener("click", clearLogs);
  var diag = $("#btn-diagnostics");
  if (diag) diag.addEventListener("click", viewDiagnostics);

  wireAndroidIdAndScope();
  wireExtras();
}

function init() {
  wire();
  if (!hasBridge()) {
    showNoBridge();
    return;
  }

  var initLogged = false;
  var logInit = function () {
    if (initLogged) return;
    initLogged = true;
    uiLog("webui init: bridge available; ua=" + (navigator.userAgent || "?").slice(0, 120));
  };
  refresh().then(logInit, logInit);
  setTimeout(logInit, 3000);
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", init);
} else {
  init();
}
