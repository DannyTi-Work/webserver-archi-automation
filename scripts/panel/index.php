<?php
// scripts/panel/index.php — dashboard for the WSA web admin panel (Phase 8).
// Reads state via scripts/status.sh (through sudo) and posts actions to
// actions.php. All output is HTML-escaped; no request data reaches a shell.
declare(strict_types=1);

require_once __DIR__ . '/bootstrap.php';

$cfg = panel_config();
$csrf = csrf_token();
$recentActions = action_log_tail(30);

// Managed databases live in their own module; load them for the Databases tab.
$databases = [];
$dbResult = run_privileged('databases', ['--json'], [], 60);
if ($dbResult[0] === 0) {
    $decodedDb = json_decode($dbResult[1], true);
    if (is_array($decodedDb) && is_array($decodedDb['databases'] ?? null)) {
        $databases = $decodedDb['databases'];
    }
}

// Managed users for the Users tab and the owner selectors.
$users = [];
$userResult = run_privileged('users', ['--json'], [], 60);
if ($userResult[0] === 0) {
    $decodedUsers = json_decode($userResult[1], true);
    if (is_array($decodedUsers) && is_array($decodedUsers['users'] ?? null)) {
        $users = $decodedUsers['users'];
    }
}

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
      flex-direction: column;
      gap: 8px;
      align-items: stretch;
    }

    .actions-grid {
      grid-template-columns: repeat(auto-fit, minmax(270px, 1fr));
    }

    .action {
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 12px;
    }

    .action h3 {
      font-size: 13px;
      margin: 0 0 2px;
    }

    .action p {
      margin: 0 0 8px;
    }

    .action input:not([type=checkbox]),
    .action select {
      width: 100%;
      min-width: 0;
    }

    .action input[type=checkbox] {
      width: auto;
    }

    .action button,
    .maintenance button {
      align-self: flex-start;
    }

    .button-danger {
      background: var(--bad);
      color: #1a0808;
    }

    .button-quiet {
      background: transparent;
      color: var(--fg);
      border: 1px solid var(--line);
    }

    .button-small {
      padding: 4px 8px;
      font-size: 12px;
    }

    .row-actions {
      display: flex;
      gap: 6px;
      flex-wrap: wrap;
    }

    .row-actions form {
      margin: 0;
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

    .muted {
      color: var(--muted);
    }

    .output {
      border: 1px solid var(--line);
      border-radius: 6px;
      padding: 10px 12px;
      background: var(--bg);
    }

    .tabs {
      display: flex;
      gap: 8px;
      margin: 4px 0 18px;
      border-bottom: 1px solid var(--line);
    }

    .tab {
      background: transparent;
      color: var(--muted);
      border: 0;
      border-bottom: 2px solid transparent;
      border-radius: 0;
      padding: 8px 14px;
      font-size: 14px;
    }

    .tab.active {
      color: var(--fg);
      border-bottom-color: var(--accent);
    }

    .tab-panel[hidden] {
      display: none;
    }
  </style>
</head>

<body>

  <h1>WSA Control Panel</h1>
  <div class="sub">Managed on this VPS &middot; <code><?= e($panelUrl) ?></code></div>

  <div class="tabs">
    <button class="tab active" data-tab="domains">Domains</button>
    <button class="tab" data-tab="databases">Databases</button>
    <button class="tab" data-tab="users">Users</button>
  </div>

  <div id="tab-domains" class="tab-panel">
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

  <div class="card">
    <h2>Server maintenance</h2>
    <p class="small">Server-wide tasks — no domain input needed.</p>
    <div class="grid actions-grid">
      <form class="action" data-action="fetch_wp">
        <h3>Fetch WordPress package</h3>
        <p class="small">Download or refresh the shared template in <code>/var/lib/wsa/wordpress</code>. Does not create a site.</p>
        <button class="button-quiet">Fetch WordPress package</button>
      </form>
    </div>
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
            <th>Owner</th>
            <th>App</th>
            <th>Certificate</th>
            <th>HTTP / HTTPS</th>
            <th>Database</th>
            <th>Docroot / logs</th>
            <th>Actions</th>
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
              <td class="small"><?= e((string)($domain['owner'] ?? 'admin')) ?></td>
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
              <td>
                <div class="row-actions">
                  <form data-action="smoke">
                    <input type="hidden" name="domain" value="<?= e($domain['domain'] ?? '') ?>">
                    <button class="button-small">Smoke test</button>
                  </form>
                  <form data-action="renew_domain">
                    <input type="hidden" name="domain" value="<?= e($domain['domain'] ?? '') ?>">
                    <button class="button-small button-quiet">Renew dry-run</button>
                  </form>
                </div>
              </td>
            </tr>
          <?php endforeach; ?>
        </tbody>
      </table>
    <?php endif; ?>
  </div>

  <div class="card" id="domain-actions-card">
    <h2>Domain actions</h2>
    <p class="small">Each action needs a domain. For an existing site, you can copy its name from the Domains table above.</p>
    <div class="grid actions-grid">
      <form class="action" data-action="add">
        <h3>Add domain</h3>
        <p class="small">Create docroot, database/user and vhost. A duplicate domain is rejected.</p>
        <label>Domain <input name="domain" required placeholder="example.com"></label>
        <label>App
          <select name="app">
            <option value="static">static</option>
            <option value="wordpress">wordpress</option>
          </select>
        </label>
        <label>Database
          <select name="db">
            <option value="">create dedicated DB</option>
            <?php foreach ($databases as $dbRow): ?>
              <option value="<?= e((string)($dbRow['name'] ?? '')) ?>"><?= e((string)($dbRow['name'] ?? '')) ?><?= ((string)($dbRow['attached_to'] ?? '-') !== '-') ? ' (in use)' : '' ?></option>
            <?php endforeach; ?>
          </select>
        </label>
        <label>Owner
          <select name="owner">
            <option value="">admin (legacy layout)</option>
            <?php foreach ($users as $u): ?>
              <option value="<?= e((string)($u['user'] ?? '')) ?>"><?= e((string)($u['user'] ?? '')) ?> (<?= e((string)($u['state'] ?? '')) ?>)</option>
            <?php endforeach; ?>
          </select>
        </label>
        <p class="small">Select an existing database to connect it at deploy time. Selecting a user creates user-prefixed paths, DB names and uses that user's PHP-FPM pool.</p>
        <button>Add domain</button>
      </form>
      <form class="action" data-action="tls">
        <h3>Issue TLS</h3>
        <p class="small">Issue and install a certificate for this domain only.</p>
        <label>Domain <input name="domain" required placeholder="example.com"></label>
        <label><input type="checkbox" name="staging" value="1"> staging (untrusted test cert)</label>
        <button>Issue TLS</button>
      </form>
      <form class="action" data-action="remove">
        <h3>Remove domain</h3>
        <p class="small error">Destructive: deletes docroot, logs, database and user. Certificates are left on disk.</p>
        <label>Domain <input name="domain" required placeholder="example.com"></label>
        <button class="button-danger">Remove domain</button>
      </form>
    </div>
  </div>
  </div><!-- /tab-domains -->

  <div id="tab-databases" class="tab-panel" hidden>
    <div class="card" id="databases-card">
      <h2>Databases <span class="small">(<?= count($databases) ?>)</span></h2>
      <p class="small">Managed MariaDB databases. Passwords stay in <code>.env</code> (mode 600).</p>
      <?php if (empty($databases)): ?>
        <p class="small">No managed databases yet. Create one below.</p>
      <?php else: ?>
        <table>
          <thead><tr><th>Database</th><th>User</th><th>Owner</th><th>Password</th><th>Used by</th><th>Actions</th></tr></thead>
          <tbody>
            <?php foreach ($databases as $dbRow): ?>
              <?php $dbName = (string)($dbRow['name'] ?? ''); ?>
              <tr>
                <td><strong><?= e($dbName) ?></strong><?= empty($dbRow['db_present']) ? ' <span class="bad">missing</span>' : '' ?></td>
                <td class="small"><?= e((string)($dbRow['user'] ?? '')) ?></td>
                <td class="small"><?= e((string)($dbRow['owner'] ?? 'admin')) ?></td>
                <td class="small"><?= !empty($dbRow['password_present']) ? 'in .env' : 'missing' ?></td>
                <td class="small"><?= e((string)($dbRow['attached_to'] ?? '-')) ?></td>
                <td>
                  <form data-action="db_delete">
                    <input type="hidden" name="name" value="<?= e($dbName) ?>">
                    <button class="button-small button-danger">Delete</button>
                  </form>
                </td>
              </tr>
            <?php endforeach; ?>
          </tbody>
        </table>
      <?php endif; ?>
    </div>

    <div class="card">
      <h2>Database actions</h2>
      <p class="small">Create an empty database, then attach it to WordPress with the Add domain form's Database selector (or with Attach below).</p>
      <div class="grid actions-grid">
        <form class="action" data-action="db_create">
          <h3>Create database</h3>
          <p class="small">Creates the DB and a least-privilege user; password is generated into <code>.env</code>.</p>
          <label>Database name <input name="name" required placeholder="blogdb"></label>
          <label>User (optional) <input name="dbuser" placeholder="defaults to &lt;name&gt;_u"></label>
          <label>Owner
            <select name="owner">
              <option value="">admin (no prefix)</option>
              <?php foreach ($users as $u): ?>
                <option value="<?= e((string)($u['user'] ?? '')) ?>"><?= e((string)($u['user'] ?? '')) ?> (<?= e((string)($u['state'] ?? '')) ?>)</option>
              <?php endforeach; ?>
            </select>
          </label>
          <button>Create database</button>
        </form>
        <form class="action" data-action="db_attach">
          <h3>Attach to WordPress</h3>
          <p class="small">Point an existing WordPress site at this database by rewriting its <code>wp-config.php</code>.</p>
          <label>Database
            <select name="name" required>
              <option value="">select a database</option>
              <?php foreach ($databases as $dbRow): ?>
                <option value="<?= e((string)($dbRow['name'] ?? '')) ?>"><?= e((string)($dbRow['name'] ?? '')) ?></option>
              <?php endforeach; ?>
            </select>
          </label>
          <label>Domain <input name="domain" required placeholder="example.com"></label>
          <button>Attach database</button>
        </form>
      </div>
    </div>
  </div><!-- /tab-databases -->

  <div id="tab-users" class="tab-panel" hidden>
    <div class="card" id="users-card">
      <h2>Users <span class="small">(<?= count($users) ?>)</span></h2>
      <p class="small">Each user has a Linux account, a dedicated PHP-FPM pool and prefixed resources. Suspending disables the pool and locks that user's DB accounts.</p>
      <?php if (empty($users)): ?>
        <p class="small">No managed users yet. Create one below.</p>
      <?php else: ?>
        <table>
          <thead><tr><th>User</th><th>Role</th><th>State</th><th>Resources</th><th>FPM socket</th><th>Actions</th></tr></thead>
          <tbody>
            <?php foreach ($users as $u): ?>
              <?php $uname = (string)($u['user'] ?? ''); ?>
              <tr>
                <td><strong><?= e($uname) ?></strong><?= empty($u['os_user']) ? ' <span class="bad">no OS user</span>' : '' ?></td>
                <td><?= e((string)($u['role'] ?? '')) ?></td>
                <td class="<?= (($u['state'] ?? '') === 'active') ? 'ok' : 'idle' ?>"><?= e((string)($u['state'] ?? '')) ?></td>
                <td><?= e((string)($u['owned'] ?? '0')) ?></td>
                <td class="small"><code><?= e((string)($u['socket'] ?? '')) ?></code></td>
                <td>
                  <div class="row-actions">
                    <?php if (($u['state'] ?? '') === 'active'): ?>
                      <form data-action="user_suspend">
                        <input type="hidden" name="user" value="<?= e($uname) ?>">
                        <button class="button-small button-quiet">Suspend</button>
                      </form>
                    <?php else: ?>
                      <form data-action="user_unsuspend">
                        <input type="hidden" name="user" value="<?= e($uname) ?>">
                        <button class="button-small button-quiet">Unsuspend</button>
                      </form>
                    <?php endif; ?>
                    <form data-action="user_delete">
                      <input type="hidden" name="user" value="<?= e($uname) ?>">
                      <button class="button-small button-danger">Delete</button>
                    </form>
                  </div>
                </td>
              </tr>
            <?php endforeach; ?>
          </tbody>
        </table>
      <?php endif; ?>
    </div>

    <div class="card">
      <h2>User actions</h2>
      <div class="grid actions-grid">
        <form class="action" data-action="user_create">
          <h3>Create user</h3>
          <p class="small">Creates a Linux user, home directory and a dedicated PHP-FPM pool. Leave password blank to generate one stored in <code>/var/lib/wsa/users/&lt;user&gt;.password</code>.</p>
          <label>User name <input name="user" required placeholder="alice"></label>
          <label>Role
            <select name="role">
              <option value="user">user</option>
              <option value="admin">admin</option>
            </select>
          </label>
          <label>Password (optional) <input name="password" type="password" autocomplete="new-password"></label>
          <button>Create user</button>
        </form>
      </div>
    </div>
  </div><!-- /tab-users -->

  <div class="card">
    <h2>Last action output</h2>
    <pre id="result" class="small output">Ready.</pre>
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
              <?php
              // Certbot and `nginx -t` write informational lines to stderr even
              // on success, so stderr alone must not make a row look failed.
              // Show stdout first for successes, stderr first for failures.
              $failed = (($entry['outcome'] ?? '') !== 'success');
              $detail = $failed
                ? ((string)($entry['stderr'] ?? '') ?: (string)($entry['stdout'] ?? ''))
                : ((string)($entry['stdout'] ?? '') ?: (string)($entry['stderr'] ?? ''));
              ?>
              <td>
                <span class="small"><?= e(substr((string)($entry['args'] ?? ''), 0, 120)) ?></span>
                <?php if ($detail !== ''): ?>
                  <br><span class="<?= $failed ? 'error small' : 'small' ?>"><?= e(substr($detail, 0, 160)) ?></span>
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
        ['domains-card', 'databases-card', 'domain-actions-card', 'users-card', 'log-card'].forEach(function (id) {
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

    document.querySelectorAll('.tab').forEach(function (btn) {
      btn.addEventListener('click', function () {
        document.querySelectorAll('.tab').forEach(function (b) {
          b.classList.toggle('active', b === btn);
        });
        document.querySelectorAll('.tab-panel').forEach(function (panel) {
          panel.hidden = (panel.id !== 'tab-' + btn.dataset.tab);
        });
      });
    });

    // Delegated so buttons inside #domains-card keep working after that card
    // is replaced by refreshState().
    document.addEventListener('submit', function (ev) {
      const form = ev.target.closest('form[data-action]');
      if (!form) return;
      ev.preventDefault();
      const payload = {};
      new FormData(form).forEach(function (value, key) {
        if (key !== 'csrf_token') payload[key] = value;
      });
      call(form.dataset.action, payload);
    });
  </script>

</body>

</html>