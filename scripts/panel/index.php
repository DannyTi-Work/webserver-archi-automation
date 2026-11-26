<?php
// scripts/panel/index.php — dashboard for the WSA web admin panel (Phase 8).
// Reads state via scripts/status.sh (through sudo) and posts actions to
// actions.php. All output is HTML-escaped; no request data reaches a shell.
declare(strict_types=1);

require_once __DIR__ . '/bootstrap.php';

$cfg = panel_config();
$csrf = csrf_token();
$recentActions = action_log_tail(30);

$statusResult = run_privileged('status', ['--json'], [], 60);
$state = null;
$statusError = '';
if ($statusResult[0] !== 0) {
  $statusError = $statusResult[2] !== '' ? $statusResult[2] : $statusResult[1];
} else {
  $state = json_decode($statusResult[1], true);
  if (!is_array($state)) {
    $statusError = 'status.sh returned invalid JSON';
    $state = null;
  }
}

$stack = $state['stack'] ?? [];
$domains = $state['domains'] ?? [];

/** HTML escape helper. */
function e($value): string
{
  return htmlspecialchars((string) $value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

/** Inline tone for a service state. */
function state_tone(string $value): string
{
  return match ($value) {
    'active', 'present' => 'ok',
    'inactive', 'absent', 'failed' => 'bad',
    default => 'idle',
  };
}

$panelUrl = 'https://' . $cfg['PANEL_DOMAIN'] . ':' . $cfg['PANEL_PORT'] . $cfg['ADMIN_PATH'] . '/';
?>
<!doctype html>
<html lang="en">

<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>WSA Control Panel</title>
  <style>
    :root {
      --bg: #0f1419;
      --card: #1a222b;
      --line: #2b3744;
      --fg: #e6edf3;
      --muted: #8b98a5;
      --ok: #3fb950;
      --bad: #f85149;
      --idle: #d29922;
      --accent: #58a6ff;
    }

    * {
      box-sizing: border-box;
    }

    body {
      margin: 0;
      padding: 24px;
      background: var(--bg);
      color: var(--fg);
      font: 14px/1.5 system-ui, -apple-system, Segoe UI, Roboto, sans-serif;
    }

    h1 {
      font-size: 20px;
      margin: 0 0 4px;
    }

    h2 {
      font-size: 15px;
      margin: 0 0 12px;
    }

    .sub {
      color: var(--muted);
      margin-bottom: 20px;
    }

    .card {
      background: var(--card);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 16px;
      margin-bottom: 16px;
    }

    .grid {
      display: grid;
      gap: 12px;
      grid-template-columns: repeat(auto-fit, minmax(230px, 1fr));
    }

    .badge {
      display: inline-block;
      padding: 2px 8px;
      border-radius: 12px;
      font-size: 12px;
      border: 1px solid var(--line);
    }

    .ok {
      color: var(--ok);
    }

    .bad {
      color: var(--bad);
    }

    .idle {
      color: var(--idle);
    }

    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 13px;
    }

    th,
    td {
      text-align: left;
      padding: 8px 10px;
      border-bottom: 1px solid var(--line);
      vertical-align: top;
    }

    th {
      color: var(--muted);
      font-weight: 600;
    }

    code {
      color: var(--accent);
      font-size: 12px;
    }

    .small {
      color: var(--muted);
      font-size: 12px;
    }

    form {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      align-items: flex-end;
    }

    label {
      display: flex;
      flex-direction: column;
      gap: 4px;
      font-size: 12px;
      color: var(--muted);
    }

    input,
    select {
      background: var(--bg);
      color: var(--fg);
      border: 1px solid var(--line);
      border-radius: 5px;
      padding: 6px 8px;
      min-width: 130px;
    }

    input[type=checkbox] {
      min-width: 0;
    }

    button {
      background: var(--accent);
      color: #06121f;
      border: 0;
      border-radius: 5px;
      padding: 7px 12px;
      font-weight: 600;
      cursor: pointer;
    }

    button:hover {
      filter: brightness(1.1);
    }

    pre {
      white-space: pre-wrap;
      word-break: break-word;
      margin: 0;
      font: 12px/1.5 ui-monospace, monospace;
    }

    .error {
      color: var(--bad);
    }
  </style>
</head>

<body>

  <h1>WSA Control Panel</h1>
  <div class="sub">Managed on this VPS &middot; <code><?= e($panelUrl) ?></code></div>

  <div class="card">
    <h2>Stack state</h2>
    <?php if ($statusError !== ''): ?>
      <p class="error">Cannot read state: <?= e($statusError) ?></p>
    <?php else: ?>
      <div class="grid">
        <?php foreach (
          [
            'nginx' => 'nginx',
            'mariadb' => 'MariaDB',
            'php_fpm' => 'PHP-FPM',
            'certbot_timer' => 'certbot.timer',
            'ufw' => 'UFW',
            'default_reject' => 'default-reject',
          ] as $key => $label
        ): ?>
          <?php $value = (string) ($stack[$key] ?? 'unknown'); ?>
          <div>
            <div class="small"><?= e($label) ?></div>
            <span class="badge <?= e(state_tone($value)) ?>"><?= e($value) ?></span>
          </div>
        <?php endforeach; ?>
        <div>
          <div class="small">PHP version</div>
          <span class="badge"><?= e($stack['php_version'] ?? 'unknown') ?></span>
        </div>
      </div>
    <?php endif; ?>
  </div>

  <div class="card" id="domains-card">
    <h2>Domains <span class="small">(<?= count($domains) ?>)</span></h2>
    <?php if (empty($domains)): ?>
      <p class="small">No domains detected.</p>
    <?php else: ?>
      <table>
        <thead>
          <tr>
            <th>Domain</th>
            <th>App</th>
            <th>Certificate</th>
            <th>HTTP / HTTPS</th>
            <th>Database</th>
            <th>Docroot / logs</th>
          </tr>
        </thead>
        <tbody>
          <?php foreach ($domains as $domain): ?>
            <?php
            $certPresent = !empty($domain['cert_present']);
            $certText = $certPresent
              ? 'present · ' . ($domain['cert_expiry'] ?? '') . ' (' . ($domain['cert_days_left'] ?? '') . 'd)'
              : 'none';
            ?>
            <tr>
              <td><strong><?= e($domain['domain'] ?? '') ?></strong></td>
              <td>
                <?= e($domain['app'] ?? '') ?>
                <?php if (!empty($domain['wp_version'])): ?>
                  <span class="small">v<?= e($domain['wp_version']) ?></span>
                <?php endif; ?>
              </td>
              <td class="<?= $certPresent ? 'ok' : 'bad' ?>"><?= e($certText) ?></td>
              <td><span
                  class="<?= (($domain['http_status'] ?? '') === '200') ? 'ok' : 'idle' ?>"><?= e($domain['http_status'] ?? '') ?></span>
                / <span
                  class="<?= (($domain['https_status'] ?? '') === '200') ? 'ok' : 'bad' ?>"><?= e($domain['https_status'] ?? '') ?></span>
              </td>
              <td class="small"><?= e($domain['database'] ?? '') ?><br><?= e($domain['db_user'] ?? '') ?></td>
              <td class="small">
                <code><?= e($domain['docroot'] ?? '') ?></code><br>
                <?= e($domain['logs']['access'] ?? '') ?><br>
                <?= e($domain['logs']['error'] ?? '') ?>
                <?php if (!empty($domain['last_access_log_line'])): ?>
                  <br><span class="small">last: <?= e(substr($domain['last_access_log_line'], 0, 120)) ?></span>
                <?php endif; ?>
                <?php if (!empty($domain['last_error_log_line'])): ?>
                  <br><span class="error small">err: <?= e(substr($domain['last_error_log_line'], 0, 120)) ?></span>
                <?php endif; ?>
              </td>
            </tr>
          <?php endforeach; ?>
        </tbody>
      </table>
    <?php endif; ?>
  </div>

  <div class="card">
    <h2>Actions</h2>
    <div class="grid">
      <form data-action="add">
        <label>Domain <input name="domain" required placeholder="example.com"></label>
        <label>App
          <select name="app">
            <option value="static">static</option>
            <option value="wordpress">wordpress</option>
          </select>
        </label>
        <button>Add domain</button>
      </form>
      <form data-action="tls">
        <label>Domain <input name="domain" required placeholder="example.com"></label>
        <label><input type="checkbox" name="staging" value="1"> staging</label>
        <button>Issue TLS</button>
      </form>
      <form data-action="fetch_wp">
        <button>Fetch WordPress package</button>
      </form>
      <form data-action="smoke">
        <label>Domain <input name="domain" placeholder="example.com (blank = all)"></label>
        <button>Smoke test</button>
      </form>
      <form data-action="renew"><button>Renew dry-run</button></form>
      <form data-action="remove">
        <label>Domain <input name="domain" required placeholder="example.com"></label>
        <button>Remove domain</button>
      </form>
    </div>
    <pre id="result" class="small" style="margin-top:14px">Ready.</pre>
  </div>

  <div class="card" id="log-card">
    <h2>Recent actions (persisted log)</h2>
    <?php if (empty($recentActions)): ?>
      <p class="muted">No actions recorded yet. Successes and failures are both kept in
        <code><?= e($cfg['ACTION_LOG'] ?? '/var/log/wsa-panel/actions.log') ?></code>.</p>
    <?php else: ?>
      <table>
        <thead><tr><th>Time</th><th>Action</th><th>Outcome</th><th>Exit</th><th>Details</th></tr></thead>
        <tbody>
          <?php foreach ($recentActions as $entry): ?>
            <tr>
              <td><?= e((string)($entry['ts'] ?? '')) ?></td>
              <td><?= e((string)($entry['action'] ?? '')) ?></td>
              <td class="<?= (($entry['outcome'] ?? '') === 'success') ? 'ok' : 'error' ?>">
                <?= e((string)($entry['outcome'] ?? '')) ?>
              </td>
              <td><?= e((string)($entry['exit_code'] ?? '')) ?></td>
              <td>
                <span class="small"><?= e(substr((string)($entry['args'] ?? ''), 0, 120)) ?></span>
                <?php if (!empty($entry['stderr'])): ?>
                  <br><span class="error small"><?= e(substr((string)$entry['stderr'], 0, 160)) ?></span>
                <?php elseif (!empty($entry['stdout'])): ?>
                  <br><span class="small"><?= e(substr((string)$entry['stdout'], 0, 160)) ?></span>
                <?php endif; ?>
              </td>
            </tr>
          <?php endforeach; ?>
        </tbody>
      </table>
    <?php endif; ?>
  </div>

  <script>
    const TOKEN = <?= json_encode($csrf, JSON_HEX_TAG | JSON_HEX_APOS | JSON_HEX_QUOT | JSON_HEX_AMP) ?>;
    const out = document.getElementById('result');

    // Re-render only the state cards from a fresh copy of this page. #result
    // is deliberately left alone, so the output of the action just performed
    // stays visible. The persisted log card is re-rendered from disk, which
    // keeps every earlier entry and adds the one just written.
    async function refreshState() {
      try {
        const res = await fetch('index.php?_=' + Date.now(), {
          headers: { 'Cache-Control': 'no-store' }
        });
        if (!res.ok) throw new Error('HTTP ' + res.status);
        const doc = new DOMParser().parseFromString(await res.text(), 'text/html');
        ['domains-card', 'log-card'].forEach(function (id) {
          const fresh = doc.getElementById(id);
          const current = document.getElementById(id);
          if (fresh && current) current.innerHTML = fresh.innerHTML;
        });
      } catch (err) {
        out.textContent += '\n(state refresh failed: ' + err + ')';
      }
    }

    async function call(action, payload) {
      payload = Object.assign({ action: action, csrf_token: TOKEN }, payload);
      out.textContent = 'Running ' + action + ' ...';
      try {
        const res = await fetch('actions.php', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(payload)
        });
        const data = await res.json();
        const head = data.ok ? 'OK' : 'FAILED (exit ' + data.exit_code + ')';
        out.textContent = head + '\n' + (data.error_message || '') +
          (data.output || '') + (data.error || '') +
          '\n(log saved — see Recent actions below)';
        // Refresh the domain list + log in place. No full reload, so the
        // result text above stays visible for both successes and failures.
        await refreshState();
      } catch (err) {
        out.textContent = 'Request failed: ' + err;
      }
    }

    document.querySelectorAll('form[data-action]').forEach(function (form) {
      form.addEventListener('submit', function (ev) {
        ev.preventDefault();
        const payload = {};
        new FormData(form).forEach(function (value, key) {
          if (key !== 'csrf_token') payload[key] = value;
        });
        call(form.dataset.action, payload);
      });
    });
  </script>

</body>

</html>