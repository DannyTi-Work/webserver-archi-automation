<?php
// scripts/panel/bootstrap.php — shared config, CSRF and privileged-exec helpers (Phase 8).
// Included by both index.php and actions.php. Never served directly by nginx.
declare(strict_types=1);

// setup-panel.sh copies these files outside the repo (PANEL_ROOT) and drops a
// config.local.php there pointing back at the real checkout. When running the
// panel straight from the repo, fall back to the normal relative location.
if (!defined('WSA_REPO_ROOT') && is_file(__DIR__ . '/config.local.php')) {
    require __DIR__ . '/config.local.php';
}
define('PANEL_REPO_ROOT', defined('WSA_REPO_ROOT') ? WSA_REPO_ROOT : dirname(__DIR__, 2));

/**
 * Load config/panel.conf (gitignored, mode 600). Missing keys fall back to
 * the defaults in config/panel.conf.example so the panel degrades cleanly
 * before Step 5 installs the real config.
 */
function panel_config(): array
{
    static $cfg = null;
    if ($cfg !== null) {
        return $cfg;
    }

    // setup-panel.sh mirrors these values into config.local.php because
    // config/panel.conf sits in a root-only checkout that www-data cannot read.
    $cfg = [
        'PANEL_DOMAIN' => defined('WSA_PANEL_DOMAIN') ? WSA_PANEL_DOMAIN : 'example.com',
        'PANEL_PORT' => defined('WSA_PANEL_PORT') ? WSA_PANEL_PORT : '8083',
        'ADMIN_PATH' => defined('WSA_ADMIN_PATH') ? WSA_ADMIN_PATH : '/_wsa-admin',
        'BASIC_AUTH_USER' => 'admin',
        'SESSION_SECRET_FILE' => '/etc/wsa/panel-session.key',
        'WP_TEMPLATE_DIR' => '/var/lib/wsa/wordpress',
        'ACTION_LOG' => defined('WSA_ACTION_LOG') ? WSA_ACTION_LOG : '/var/log/wsa-panel/actions.log',
    ];

    $file = PANEL_REPO_ROOT . '/config/panel.conf';
    if (is_readable($file)) {
        foreach (file($file, FILE_IGNORE_NEW_LINES) as $line) {
            $line = trim($line);
            if ($line === '' || $line[0] === '#' || strpos($line, '=') === false) {
                continue;
            }
            [$key, $value] = explode('=', $line, 2);
            $key = trim($key);
            $value = trim($value);
            if (
                strlen($value) >= 2 &&
                (($value[0] === '"' && substr($value, -1) === '"') ||
                    ($value[0] === "'" && substr($value, -1) === "'"))
            ) {
                $value = substr($value, 1, -1);
            }
            $cfg[$key] = $value;
        }
    }

    return $cfg;
}

/** Start the panel session with hardened cookie flags. */
function panel_session(): void
{
    if (session_status() === PHP_SESSION_ACTIVE) {
        return;
    }
    session_name('WSAPANEL');
    session_set_cookie_params([
        'httponly' => true,
        'samesite' => 'Strict',
        'secure' => true,
        'path' => panel_config()['ADMIN_PATH'] ?: '/',
    ]);
    session_start();
}

/** Return (and lazily create) the per-session CSRF token. */
function csrf_token(): string
{
    panel_session();
    if (empty($_SESSION['csrf_token'])) {
        $_SESSION['csrf_token'] = rtrim(strtr(base64_encode(random_bytes(32)), '+/', '-_'), '=');
    }
    return $_SESSION['csrf_token'];
}

/** Constant-time CSRF validation. */
function csrf_valid(?string $token): bool
{
    panel_session();
    return is_string($token) && isset($_SESSION['csrf_token']) &&
        hash_equals($_SESSION['csrf_token'], $token);
}

/** Emit a JSON response and stop. */
function json_response(array $data, int $status = 200): void
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE), "\n";
    exit;
}

/** Absolute paths of the scripts the panel is allowed to call. */
function panel_scripts(): array
{
    $root = PANEL_REPO_ROOT;
    return [
        'status' => $root . '/scripts/status.sh',
        'add' => $root . '/scripts/add-domain.sh',
        'tls' => $root . '/scripts/tls.sh',
        'remove' => $root . '/scripts/remove-domain.sh',
        'prepare_wp' => $root . '/scripts/prepare-wordpress.sh',
        'databases' => $root . '/scripts/databases.sh',
        'users' => $root . '/scripts/users.sh',
        'smoke' => $root . '/tests/smoke.sh',
    ];
}

/** Same intent as is_valid_domain() in lib/common.sh. */
function panel_valid_domain(string $domain): bool
{
    return (bool) preg_match(
        '/^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/i',
        $domain
    );
}

/**
 * Append one JSON line to the persistent action log (both successes and
 * failures). The log lives outside the checkout so it survives reinstalls.
 */
function action_log(string $action, string $outcome, int $exit, string $args, string $stdout, string $stderr): void
{
    $path = panel_config()['ACTION_LOG'] ?: '/var/log/wsa-panel/actions.log';
    $entry = [
        'ts' => date('c'),
        'action' => $action,
        'outcome' => $outcome,      // success | failure | rejected
        'exit_code' => $exit,
        'args' => $args,
        'stdout' => substr($stdout, 0, 20000),
        'stderr' => substr($stderr, 0, 20000),
    ];
    @file_put_contents($path, json_encode($entry, JSON_UNESCAPED_SLASHES) . "\n", FILE_APPEND | LOCK_EX);
}

/** Return the last $limit action-log entries, newest first. */
function action_log_tail(int $limit = 50): array
{
    $path = panel_config()['ACTION_LOG'] ?: '/var/log/wsa-panel/actions.log';
    if (!is_readable($path)) {
        return [];
    }
    $lines = file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    if ($lines === false) {
        return [];
    }
    $out = [];
    foreach (array_reverse($lines) as $line) {
        $entry = json_decode($line, true);
        if (is_array($entry)) {
            $out[] = $entry;
        }
        if (count($out) >= $limit) {
            break;
        }
    }
    return $out;
}

/**
 * Run one allowlisted script through sudo with an argv ARRAY — never a shell
 * string — so no request data can reach a shell. sudoers limits these paths.
 *
 * @return array{0:int,1:string,2:string} exit code, stdout, stderr
 */
function run_privileged(string $key, array $args = [], array $env = [], int $timeout = 300): array
{
    $scripts = panel_scripts();
    if (!isset($scripts[$key])) {
        return [1, '', "unknown script key: {$key}"];
    }
    // Do NOT stat() the script here: the checkout is under /root and www-data
    // cannot traverse it. sudo runs the script as root, which can reach it.
    $script = $scripts[$key];

    $cmd = ['/usr/bin/sudo', '-n', '/usr/bin/bash', $script, ...array_values($args)];
    $descriptors = [1 => ['pipe', 'w'], 2 => ['pipe', 'w']];
    $processEnv = getenv() ?: [];
    foreach ($env as $name => $value) {
        $processEnv[$name] = (string) $value;
    }

    // Neutral cwd: www-data cannot chdir into the root-only checkout.
    $proc = @proc_open($cmd, $descriptors, $pipes, '/', $processEnv);
    if (!is_resource($proc)) {
        return [1, '', 'could not start privileged process'];
    }
    stream_set_blocking($pipes[1], false);
    stream_set_blocking($pipes[2], false);

    $stdout = '';
    $stderr = '';
    $exit = 1;
    $deadline = microtime(true) + $timeout;

    while (true) {
        $read = [$pipes[1], $pipes[2]];
        $write = null;
        $except = null;
        @stream_select($read, $write, $except, 0, 200000);
        foreach ($read as $stream) {
            $chunk = fread($stream, 8192);
            if ($chunk === false || $chunk === '') {
                continue;
            }
            if ($stream === $pipes[1]) {
                $stdout .= $chunk;
            } else {
                $stderr .= $chunk;
            }
        }
        if (strlen($stdout) > 200000 || strlen($stderr) > 200000) {
            $stderr .= "\n[panel] output truncated\n";
            break;
        }
        $status = proc_get_status($proc);
        if (!$status['running']) {
            $exit = (int) $status['exitcode'];
            break;
        }
        if (microtime(true) > $deadline) {
            proc_terminate($proc, 9);
            $stderr .= "\n[panel] timeout after {$timeout}s\n";
            $exit = 124;
            break;
        }
    }

    foreach ([$pipes[1], $pipes[2]] as $pipe) {
        if (is_resource($pipe)) {
            fclose($pipe);
        }
    }
    proc_close($proc);

    return [$exit, $stdout, $stderr];
}
