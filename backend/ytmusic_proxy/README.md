# YT Music Proxy (Playwright / ytmusicapi)

This backend fetches YouTube Music home shelves and quick picks, then returns a compact JSON payload for the Flutter app.

## Why

- Better control over parsing and hotfixes.
- App can stay thin and only consume compact shelf payload.
- Still unofficial and may break if YouTube changes internals.

## Endpoints

- `GET /healthz`
- `POST /ytmusic/home`

## Request JSON (`POST /ytmusic/home`)

```json
{
  "cookie": "SAPISID=...; __Secure-3PAPISID=...; ...",
  "authUser": "0",
  "visitorData": "Cgt....",
  "hl": "en",
  "gl": "IN",
  "maxShelves": 18,
  "maxVideosPerShelf": 24,
  "strategy": "playwright"
}
```

`strategy` values:
- `playwright` (default, cookie-driven, best for personalized feed)
- `ytmusicapi` (optional fallback; requires ytmusicapi-compatible auth for personalized results)

## Response JSON

```json
{
  "ok": true,
  "backend": "playwright",
  "quickPicks": [{ "id": "...", "title": "...", "author": "..." }],
  "quickPicksLabel": "From your YouTube Music Quick Picks",
  "quickPicksFromOfficialShelf": true,
  "shelves": [
    {
      "title": "Quick picks",
      "subtitle": "",
      "videos": [{ "id": "...", "title": "...", "author": "..." }],
      "mixes": []
    }
  ]
}
```

## Run

From `backend/ytmusic_proxy`:

```bash
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
python -m playwright install chromium
uvicorn app:app --host 0.0.0.0 --port 8787
```

## Deploy

This folder now includes:

- `Dockerfile`
- `.dockerignore`
- `render.yaml`

### Render

1. Push the repo to GitHub.
2. In Render, create a new `Blueprint` or `Web Service`.
3. Point it at this repo and use `backend/ytmusic_proxy/render.yaml`, or deploy the `backend/ytmusic_proxy` directory with the included `Dockerfile`.
4. Set `YTM_BACKEND_API_KEY` if you want to lock the proxy down.
5. After deploy, confirm `https://<your-service>/healthz` returns `{"ok":true,...}`.

### Keepalive pings

If you want extra scheduled traffic hitting the service, this repo includes a GitHub Actions workflow at `.github/workflows/render-keepalive.yml`.

It sends pings on three schedules:
- every 5 minutes
- every 7 minutes with an offset
- every 10 minutes with an offset

To enable it:

1. Open your GitHub repo settings.
2. Go to `Secrets and variables` -> `Actions`.
3. Add `RENDER_KEEPALIVE_URL` with a value like `https://your-backend.onrender.com/healthz`.
4. If your backend requires a key, also add `YTM_BACKEND_API_KEY` with the same value used on Render.
5. Make sure GitHub Actions is enabled for the repository.

Note:
- Render `Starter` web services are already designed to stay on, so this is only an extra keepalive layer.
- No host can realistically be guaranteed to stay up for "10000 years"; provider restarts and maintenance can still happen.

### Other hosts

Any host that supports Docker works. The container starts `uvicorn` and listens on `${PORT}` when the platform provides one.

## Optional API key

Set backend key:

```bash
set YTM_BACKEND_API_KEY=your-secret
```

Then app side:

```bash
flutter run --dart-define=YTM_BACKEND_API_KEY=your-secret
```

## Flutter integration notes

Default backend URL used by app:
- Android emulator: `http://10.0.2.2:8787`
- Desktop/iOS/macOS/Linux: `http://127.0.0.1:8787`

Override URL at build time:

```bash
flutter run --dart-define=YTM_BACKEND_URL=http://<host>:8787
```

Override URL at runtime:

- Open `Settings` in the app.
- Tap `YT Music Backend`.
- Paste your hosted backend URL, for example `https://your-backend.onrender.com`.
- If you configured `YTM_BACKEND_API_KEY` on the server, paste the same key in the app dialog.

That runtime setting is the easiest way to stop relying on a backend running on your PC.
