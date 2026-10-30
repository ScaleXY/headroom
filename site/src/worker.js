// Serves the static site; /download and /api/latest resolve the newest Mac release with a DMG.
const REPO = "ScaleXY/headroom";
const RELEASES = `https://github.com/${REPO}/releases`;
const UA = { "User-Agent": "headroom-site" };

// The releases Atom feed lists tags newest first and, unlike the REST API, isn't
// rate-limited per IP, which matters on Cloudflare's shared egress. Mobile releases
// (mobile-v*) are skipped, and so is a release whose build hasn't uploaded its DMG yet
// (or failed), so /download never points at a missing file.
// Release assets are always named Headroom-<version>.dmg (see the Makefile).
async function latestRelease(ctx) {
  const cache = caches.default;
  const key = new Request(`https://cache.internal/${REPO}/latest-v3`);
  const hit = await cache.match(key);
  if (hit) return hit.json();

  const feed = await fetch(`${RELEASES}.atom`, { headers: UA }).then((r) => (r.ok ? r.text() : ""));
  const tags = [...feed.matchAll(/\/releases\/tag\/(v(\d[^"/?#]*))"/g)].slice(0, 5);

  let info = null;
  for (const [, name, version] of tags) {
    const dmg = `${RELEASES}/download/${name}/Headroom-${version}.dmg`;
    const res = await fetch(dmg, { method: "HEAD", redirect: "manual", headers: UA });
    if (res.status >= 300 && res.status < 400) {
      info = { version, dmg, url: `${RELEASES}/tag/${name}` };
      break;
    }
  }
  if (!info) return null;

  ctx.waitUntil(
    cache.put(key, new Response(JSON.stringify(info), { headers: { "Cache-Control": "max-age=900" } })),
  );
  return info;
}

export default {
  async fetch(request, env, ctx) {
    const { pathname } = new URL(request.url);

    if (pathname === "/download") {
      const info = await latestRelease(ctx).catch(() => null);
      return Response.redirect(info?.dmg ?? `${RELEASES}/latest`, 302);
    }

    if (pathname === "/api/latest") {
      const info = await latestRelease(ctx).catch(() => null);
      return Response.json(info ?? { version: null, dmg: null, url: RELEASES }, {
        headers: { "Cache-Control": "public, max-age=300" },
      });
    }

    return env.ASSETS.fetch(request);
  },
};
