import { Buffer } from 'node:buffer';
import { sign } from 'node:crypto';

const repository = 'tokenzz-vip/RcHarness';
const maxRequestBytes = 74_000;
const githubApi = 'https://api.github.com';

function appJWT(clientID, privateKey) {
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const header = encode({ alg: 'RS256', typ: 'JWT' });
  const claims = encode({ iss: clientID, iat: now - 60, exp: now + 480 });
  const payload = `${header}.${claims}`;
  return `${payload}.${sign('RSA-SHA256', Buffer.from(payload), privateKey).toString('base64url')}`;
}

function githubPost(path, token, body) {
  return fetch(githubApi + path, {
    method: 'POST',
    headers: {
      'Accept': 'application/vnd.github+json',
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'application/json',
      'User-Agent': 'RcHarness-Feedback',
      'X-GitHub-Api-Version': '2022-11-28',
    },
    body: JSON.stringify(body),
    redirect: 'error',
    signal: AbortSignal.timeout(7000),
  });
}

async function readFeedback(request) {
  if (!request.body) return null;
  const reader = request.body.getReader();
  const buffer = new Uint8Array(maxRequestBytes);
  let offset = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (offset + value.byteLength > maxRequestBytes) {
      await reader.cancel();
      return null;
    }
    buffer.set(value, offset);
    offset += value.byteLength;
  }
  const payload = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(buffer.subarray(0, offset)));
  if (typeof payload?.title !== 'string' || typeof payload.body !== 'string') return null;
  const title = payload.title.trim();
  const body = payload.body.trim();
  if (!title || !body || Buffer.byteLength(title) > 240 || Buffer.byteLength(body) > 12_000) return null;
  return { title, body };
}

export default {
  async fetch(request, env) {
    if (new URL(request.url).pathname !== '/api/feedback') {
      return new Response(null, { status: 404 });
    }
    if (request.method !== 'POST') {
      return new Response(null, { status: 405, headers: { Allow: 'POST' } });
    }
    const contentType = request.headers.get('content-type')?.split(';', 1)[0].trim().toLowerCase();
    if (contentType !== 'application/json') return new Response(null, { status: 415 });

    const ip = request.headers.get('CF-Connecting-IP');
    if (!ip) return new Response(null, { status: 403 });
    const perIP = await env.FEEDBACK_RATE.limit({ key: `ip:${ip}` });
    if (!perIP.success) return new Response(null, { status: 429 });

    const feedback = await readFeedback(request).catch(() => null);
    if (!feedback) return new Response(null, { status: 400 });
    const total = await env.FEEDBACK_TOTAL_RATE.limit({ key: repository });
    if (!total.success) return new Response(null, { status: 429 });

    try {
      const jwt = appJWT(env.GITHUB_APP_CLIENT_ID, env.GITHUB_APP_PRIVATE_KEY);
      const installation = await githubPost(`/app/installations/${env.GITHUB_INSTALLATION_ID}/access_tokens`, jwt, {
        repositories: ['RcHarness'],
        permissions: { issues: 'write' },
      });
      if (installation.status !== 201) return new Response(null, { status: 502 });
      const { token } = await installation.json();
      if (typeof token !== 'string' || !token) return new Response(null, { status: 502 });

      const created = await githubPost(`/repos/${repository}/issues`, token, feedback);
      if (created.status !== 201) return new Response(null, { status: 502 });
      const { number, html_url } = await created.json();
      if (!Number.isSafeInteger(number) || number < 1) return new Response(null, { status: 502 });
      return Response.json({ number, html_url }, { status: 201 });
    } catch {
      return new Response(null, { status: 502 });
    }
  },
};
