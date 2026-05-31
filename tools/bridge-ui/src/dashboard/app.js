const state = {
  selectedRunId: null,
  pollHandle: null,
};

const $ = (id) => document.getElementById(id);

async function jsonFetch(url, options = {}) {
  const response = await fetch(url, options);
  const data = await response.json();
  if (!response.ok) {
    throw new Error(data.error || `${response.status} ${response.statusText}`);
  }
  return data;
}

function flash(message, isError = false) {
  const node = $("flash");
  if (!node) return;
  node.textContent = message;
  node.style.color = isError ? "var(--bad)" : "var(--muted)";
}

function compactJson(value) {
  if (value == null) return "";
  if (typeof value === "string") return value;
  return JSON.stringify(value, null, 2);
}

function setText(node, value) {
  if ("value" in node) {
    node.value = value;
  } else {
    node.textContent = value;
  }
}

function requestBodyFromForm() {
  const form = $("flow-form");
  const data = {};
  if (!form) return data;

  for (const [key, value] of new FormData(form).entries()) {
    const text = String(value).trim();
    if (!text) continue;
    if (
      key === "rgb_asset_amount" ||
      key === "ln_to_ark_sats" ||
      key === "ark_to_rgb_sats"
    ) {
      data[key] = Number(text);
    } else {
      data[key] = text;
    }
  }
  return data;
}

async function refreshCluster() {
  const grid = $("cluster-grid");
  if (!grid) return;
  grid.innerHTML = '<div class="empty">Loading cluster state...</div>';
  try {
    const snapshot = await jsonFetch("/api/cluster");
    grid.innerHTML = snapshot.checks
      .map((check) => {
        const cls = check.ok ? "ok" : "fail";
        const status = check.ok ? "ready" : "not ready";
        const detail = check.stderr || compactJson(check.stdout);
        return `
          <div class="status-card ${cls}">
            <strong>${escapeHtml(check.name)}</strong>
            <div class="meta">${status}</div>
            ${detail ? `<pre>${escapeHtml(detail)}</pre>` : ""}
          </div>
        `;
      })
      .join("");
  } catch (error) {
    grid.innerHTML = `<div class="empty">Cluster check failed: ${escapeHtml(error.message)}</div>`;
  }
}

async function refreshPreflight() {
  const grid = $("preflight-grid");
  if (!grid) return;
  grid.innerHTML = '<div class="empty">Loading preflight checks...</div>';
  try {
    const snapshot = await jsonFetch("/api/preflight");
    const rows = [
      ["RGB asset", snapshot.rgb_asset_id],
      ["Ark asset", snapshot.ark_asset_id],
    ];
    grid.innerHTML = rows
      .map(([label, item]) => {
        const ok = item && item.ok;
        const cls = ok ? "ok" : "fail";
        const detail = ok
          ? `${item.source} · ${item.value || item.fingerprint}`
          : item?.error || "missing";
        return `
          <div class="status-card ${cls}">
            <strong>${escapeHtml(label)}</strong>
            <div class="meta">${ok ? "ready" : "missing"}</div>
            <pre>${escapeHtml(detail)}</pre>
          </div>
        `;
      })
      .join("");
  } catch (error) {
    grid.innerHTML = `<div class="empty">Preflight failed: ${escapeHtml(error.message)}</div>`;
  }
}

async function startFlow(mode) {
  flash(`Starting ${mode}...`);
  try {
    const run = await jsonFetch(`/api/flows/start/${mode}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(requestBodyFromForm()),
    });
    state.selectedRunId = run.id;
    renderRun(run);
    await refreshRuns();
    startPolling();
    flash(`Started ${mode}`);
    await refreshPreflight();
  } catch (error) {
    flash(error.message, true);
  }
}

async function refreshRuns() {
  const list = $("run-list");
  if (!list) return;
  try {
    const data = await jsonFetch("/api/flows");
    const flows = data.flows || [];
    if (flows.length === 0) {
      list.innerHTML = '<div class="empty">No runs yet.</div>';
      return;
    }
    flows.sort((a, b) => b.started_at_unix - a.started_at_unix);
    list.innerHTML = flows
      .map((run) => {
        const active = run.id === state.selectedRunId ? "active" : "";
        return `
          <button class="run-item ${active}" type="button" data-run-id="${escapeHtml(run.id)}">
            <strong>${escapeHtml(run.mode)}</strong>
            <div class="meta">${escapeHtml(run.status)} · ${escapeHtml(run.id)}</div>
          </button>
        `;
      })
      .join("");
  } catch (error) {
    list.innerHTML = `<div class="empty">Could not load runs: ${escapeHtml(error.message)}</div>`;
  }
}

async function refreshSelectedRun() {
  if (!state.selectedRunId) return;
  try {
    const run = await jsonFetch(`/api/flows/${state.selectedRunId}`);
    renderRun(run);
    await refreshRuns();
    if (run.status !== "running") {
      stopPolling();
    }
  } catch (error) {
    flash(error.message, true);
    stopPolling();
  }
}

function renderRun(run) {
  state.selectedRunId = run.id;
  const label = $("selected-run-label");
  const statePill = $("run-state");
  const timeline = $("timeline-list");
  const logTail = $("log-tail");
  const jsonView = $("json-view");

  if (label) {
    label.textContent = `${run.mode} · ${run.id}`;
  }
  if (statePill) {
    statePill.textContent = run.status;
    statePill.className = `state-pill ${run.status}`;
  }
  if (timeline) {
    const steps = run.timeline || [];
    timeline.innerHTML = steps
      .map((step) => {
        const cls = step.state || (step.observed ? "done" : "pending");
        const status = step.observed ? cls : "waiting";
        const data = step.data ? `<pre>${escapeHtml(JSON.stringify(step.data, null, 2))}</pre>` : "";
        return `
          <div class="timeline-step ${cls}">
            <span class="dot"></span>
            <div>
              <strong>${escapeHtml(step.label)}</strong>
              <div class="meta">${escapeHtml(step.flow)} · ${escapeHtml(step.step)} · ${status}</div>
              ${data}
            </div>
          </div>
        `;
      })
      .join("");
  }
  if (logTail) {
    const stdout = run.stdout_tail || [];
    const stderr = run.stderr_tail || [];
    setText(logTail, [
      stdout.length ? "stdout:" : "",
      ...stdout,
      stderr.length ? "\nstderr:" : "",
      ...stderr,
    ]
      .filter(Boolean)
      .join("\n"));
  }
  if (jsonView) {
    setText(jsonView, JSON.stringify(run, null, 2));
  }
}

function startPolling() {
  stopPolling();
  state.pollHandle = window.setInterval(refreshSelectedRun, 2000);
}

function stopPolling() {
  if (state.pollHandle) {
    window.clearInterval(state.pollHandle);
    state.pollHandle = null;
  }
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

document.addEventListener("click", (event) => {
  const startButton = event.target.closest("[data-start-flow]");
  if (startButton) {
    startFlow(startButton.dataset.startFlow);
    return;
  }

  const runButton = event.target.closest("[data-run-id]");
  if (runButton) {
    state.selectedRunId = runButton.dataset.runId;
    refreshSelectedRun();
    startPolling();
  }
});

document.addEventListener("DOMContentLoaded", () => {
  $("refresh-cluster")?.addEventListener("click", refreshCluster);
  $("refresh-preflight")?.addEventListener("click", refreshPreflight);
  $("refresh-runs")?.addEventListener("click", refreshRuns);
  refreshCluster();
  refreshPreflight();
  refreshRuns();
  window.setInterval(refreshCluster, 15000);
  window.setInterval(refreshPreflight, 15000);
  window.setInterval(refreshRuns, 5000);
});
