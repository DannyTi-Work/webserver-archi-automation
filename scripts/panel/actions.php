<?php
// scripts/panel/actions.php — POST-only action endpoints (Phase 8).
// Every action delegates to an existing guarded script through sudo-limited
// execution (see bootstrap.php + config/sudoers-panel.conf.example).
declare(strict_types=1);

require_once __DIR__ . '/bootstrap.php';

$action = $_GET['action'] ?? ($_POST['action'] ?? '');

// Token endpoint used by index.php to embed the CSRF token in forms.
if ($action === 'token') {
    json_response(['csrf_token' => csrf_token()]);
}

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    json_response(['ok' => false, 'error' => 'POST required'], 405);
}

// Accept JSON or form-encoded bodies.
$input = [];
if (stripos($_SERVER['CONTENT_TYPE'] ?? '', 'application/json') !== false) {
    $raw = file_get_contents('php://input');
    $decoded = json_decode($raw ?: '', true);
    if (is_array($decoded)) {
        $input = $decoded;
    }
} else {
    $input = $_POST;
}

// JSON requests carry the action in the body rather than $_GET/$_POST.
if ($action === '' && isset($input['action'])) {
    $action = (string) $input['action'];
}

$token = $input['csrf_token'] ?? ($_SERVER['HTTP_X_CSRF_TOKEN'] ?? null);
if (!csrf_valid($token)) {
    action_log($action, 'rejected', 403, '{}', '', 'invalid CSRF token');
    json_response(['ok' => false, 'error' => 'invalid CSRF token'], 403);
}

$domain = isset($input['domain']) ? trim((string) $input['domain']) : '';
$app = isset($input['app']) ? (string) $input['app'] : 'static';

/** Validate a required domain argument before any privileged call. */
$need_domain = static function (string $value): void {
    if (!panel_valid_domain($value)) {
        json_response(['ok' => false, 'error' => 'invalid domain'], 400);
    }
};

/** Translate run_privileged()'s tuple into the panel's JSON shape and persist it. */
$respond = static function (array $result) use ($action, $input): void {
    [$exit, $stdout, $stderr] = $result;
    // Persist EVERY outcome — success and failure alike — for panel inspection.
    $args = json_encode([
        'domain' => $input['domain'] ?? '',
        'app' => $input['app'] ?? '',
        'staging' => !empty($input['staging']),
        'name' => $input['name'] ?? '',
        'db' => $input['db'] ?? '',
        'owner' => $input['owner'] ?? '',
    ], JSON_UNESCAPED_SLASHES);
    action_log($action, $exit === 0 ? 'success' : 'failure', $exit, $args ?: '{}', $stdout, $stderr);
    json_response([
        'ok' => $exit === 0,
        'exit_code' => $exit,
        'output' => substr($stdout, 0, 20000),
        'error' => substr($stderr, 0, 20000),
    ], $exit === 0 ? 200 : 500);
};

switch ($action) {
    case 'add':
        $need_domain($domain);
        if (!in_array($app, ['static', 'wordpress'], true)) {
            json_response(['ok' => false, 'error' => 'app must be static or wordpress'], 400);
        }
        $args = [$domain, '--app', $app];
        // Optional: attach an existing managed database instead of creating a
        // dedicated one (Hestia-style: empty DB + WordPress connect at deploy).
        $db = trim((string)($input['db'] ?? ''));
        if ($db !== '') {
            if (!preg_match('/^[A-Za-z0-9_]{1,60}$/', $db)) {
                json_response(['ok' => false, 'error' => 'invalid database name'], 400);
            }
            array_push($args, '--db', $db);
        }
        $owner = trim((string)($input['owner'] ?? ''));
        if ($owner !== '') {
            if (!preg_match('/^[a-z][a-z0-9_-]{0,31}$/', $owner)) {
                json_response(['ok' => false, 'error' => 'invalid user name'], 400);
            }
            array_push($args, '--owner', $owner);
        }
        $respond(run_privileged('add', $args));
        break;

    case 'tls':
        $need_domain($domain);
        $env = [];
        if (!empty($input['staging'])) {
            $env['LE_STAGING'] = '1';
        }
        $respond(run_privileged('tls', [$domain], $env, 600));
        break;

    case 'renew':
        $respond(run_privileged('tls', ['--renew-dry-run'], [], 600));
        break;

    case 'renew_domain':
        // Per-domain dry-run from the Domains table — only this lineage.
        $need_domain($domain);
        $respond(run_privileged('tls', ['--renew-dry-run', $domain], [], 300));
        break;

    case 'smoke':
        $args = [];
        if ($domain !== '') {
            $need_domain($domain);
            $args[] = $domain;
        }
        $respond(run_privileged('smoke', $args, [], 300));
        break;

    case 'remove':
        $need_domain($domain);
        $respond(run_privileged('remove', [$domain, '--yes']));
        break;

    case 'db_create':
        $name = trim((string)($input['name'] ?? ''));
        if (!preg_match('/^[A-Za-z0-9_]{1,60}$/', $name)) {
            json_response(['ok' => false, 'error' => 'invalid database name'], 400);
        }
        $args = ['create', $name];
        $dbuser = trim((string)($input['dbuser'] ?? ''));
        if ($dbuser !== '') {
            if (!preg_match('/^[A-Za-z0-9_]{1,60}$/', $dbuser)) {
                json_response(['ok' => false, 'error' => 'invalid database user'], 400);
            }
            array_push($args, '--user', $dbuser);
        }
        $owner = trim((string)($input['owner'] ?? ''));
        if ($owner !== '') {
            if (!preg_match('/^[a-z][a-z0-9_-]{0,31}$/', $owner)) {
                json_response(['ok' => false, 'error' => 'invalid user name'], 400);
            }
            array_push($args, '--owner', $owner);
        }
        $respond(run_privileged('databases', $args));
        break;

    case 'db_delete':
        $name = trim((string)($input['name'] ?? ''));
        if (!preg_match('/^[A-Za-z0-9_]{1,60}$/', $name)) {
            json_response(['ok' => false, 'error' => 'invalid database name'], 400);
        }
        $respond(run_privileged('databases', ['delete', $name, '--yes']));
        break;

    case 'db_attach':
        $name = trim((string)($input['name'] ?? ''));
        $need_domain($domain);
        if (!preg_match('/^[A-Za-z0-9_]{1,60}$/', $name)) {
            json_response(['ok' => false, 'error' => 'invalid database name'], 400);
        }
        $respond(run_privileged('databases', ['attach', $name, $domain]));
        break;

    case 'user_create':
        $user = trim((string)($input['user'] ?? ''));
        if (!preg_match('/^[a-z][a-z0-9_-]{0,31}$/', $user)) {
            json_response(['ok' => false, 'error' => 'invalid user name'], 400);
        }
        $args = ['create', $user];
        $role = trim((string)($input['role'] ?? 'user'));
        if (!in_array($role, ['admin', 'user'], true)) {
            json_response(['ok' => false, 'error' => 'invalid role'], 400);
        }
        array_push($args, '--role', $role);
        $pass = (string)($input['password'] ?? '');
        if ($pass !== '') {
            array_push($args, '--password', $pass);
        }
        $respond(run_privileged('users', $args));
        break;

    case 'user_suspend':
    case 'user_unsuspend':
        $user = trim((string)($input['user'] ?? ''));
        if (!preg_match('/^[a-z][a-z0-9_-]{0,31}$/', $user)) {
            json_response(['ok' => false, 'error' => 'invalid user name'], 400);
        }
        $sub = $action === 'user_suspend' ? 'suspend' : 'unsuspend';
        $respond(run_privileged('users', [$sub, $user]));
        break;

    case 'user_delete':
        $user = trim((string)($input['user'] ?? ''));
        if (!preg_match('/^[a-z][a-z0-9_-]{0,31}$/', $user)) {
            json_response(['ok' => false, 'error' => 'invalid user name'], 400);
        }
        $respond(run_privileged('users', ['delete', $user, '--yes']));
        break;

    case 'fetch_wp':
        // Only download/refresh the shared template. Deploying a site is done
        // with Add domain (App = wordpress), so this action needs no domain.
        $respond(run_privileged('prepare_wp', [], [], 600));
        break;

    default:
        json_response(['ok' => false, 'error' => 'unknown action'], 400);
}
