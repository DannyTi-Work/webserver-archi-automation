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

$token = $input['csrf_token'] ?? ($_SERVER['HTTP_X_CSRF_TOKEN'] ?? null);
if (!csrf_valid($token)) {
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

/** Translate run_privileged()'s tuple into the panel's JSON shape. */
$respond = static function (array $result): void {
    [$exit, $stdout, $stderr] = $result;
    json_response([
        'ok'        => $exit === 0,
        'exit_code' => $exit,
        'output'    => substr($stdout, 0, 20000),
        'error'     => substr($stderr, 0, 20000),
    ], $exit === 0 ? 200 : 500);
};

switch ($action) {
    case 'add':
        $need_domain($domain);
        if (!in_array($app, ['static', 'wordpress'], true)) {
            json_response(['ok' => false, 'error' => 'app must be static or wordpress'], 400);
        }
        $respond(run_privileged('add', [$domain, '--app', $app]));
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
        if (($input['confirm'] ?? '') !== $domain) {
            json_response(['ok' => false, 'error' => 'type the domain name to confirm removal'], 400);
        }
        $respond(run_privileged('remove', [$domain, '--yes']));
        break;

    case 'deploy_wp':
        $need_domain($domain);
        // prepare-wordpress.sh is idempotent; run it once before adding the site.
        $prepare = run_privileged('prepare_wp', [], [], 600);
        if ($prepare[0] !== 0) {
            $respond($prepare);
        }
        $respond(run_privileged('add', [$domain, '--app', 'wordpress']));
        break;

    default:
        json_response(['ok' => false, 'error' => 'unknown action'], 400);
}
