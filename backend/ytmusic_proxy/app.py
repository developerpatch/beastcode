import asyncio
import os
import re
import time
from typing import Any, Optional

from fastapi import FastAPI, Header, HTTPException, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field
from playwright.async_api import async_playwright
import httpx

try:
    from ytmusicapi import YTMusic
except Exception:
    YTMusic = None

try:
    import yt_dlp
except Exception:
    yt_dlp = None


APP_TITLE = "YT Music Home Proxy"
API_KEY = os.getenv("YTM_BACKEND_API_KEY", "").strip()
AUDIO_COOKIE = (
    os.getenv("YTM_BACKEND_COOKIE", "").strip()
    or os.getenv("YTM_BACKEND_YOUTUBE_COOKIE", "").strip()
)
WEB_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"
)
_AUDIO_URL_CACHE: dict[str, tuple[dict[str, Any], float]] = {}
_AUDIO_URL_TTL_SECONDS = 8 * 60


class HomeRequest(BaseModel):
    cookie: str = ""
    authUser: str = "0"
    visitorData: Optional[str] = None
    gl: str = "IN"
    hl: str = "en"
    maxShelves: int = Field(default=18, ge=1, le=40)
    maxVideosPerShelf: int = Field(default=24, ge=1, le=60)
    strategy: str = Field(default="playwright")
    ytmusicAuth: Optional[dict[str, Any]] = None


def _normalize_auth_user(raw: str) -> str:
    digits = re.sub(r"[^0-9]", "", (raw or "").strip())
    return digits or "0"


def _parse_cookie_header(raw_cookie: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for part in (raw_cookie or "").split(";"):
        trimmed = part.strip()
        if not trimmed or "=" not in trimmed:
            continue
        key, value = trimmed.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key or not value:
            continue
        out[key] = value
    return out


def _quick_score(title: str) -> int:
    normalized = re.sub(r"[^a-z0-9]+", " ", (title or "").lower()).strip()
    if "quick picks" in normalized or "quickpicks" in normalized:
        return 6
    if (
        "picked for you" in normalized
        or "recommended for you" in normalized
        or "start here" in normalized
    ):
        return 4
    if "listen again" in normalized:
        return 2
    return 0


def _first_non_empty(value: Any, fallback: str = "") -> str:
    if isinstance(value, str):
        text = value.strip()
        return text if text else fallback
    return fallback


def _track_signature(title: str, author: str) -> str:
    clean_title = re.sub(r"[^a-z0-9\s]", " ", (title or "").lower())
    clean_title = re.sub(
        r"\b(official|audio|video|lyrics?|lyrical|visualizer|feat|ft|prod|version|remix|edit|live)\b",
        " ",
        clean_title,
    )
    clean_title = re.sub(r"\s+", " ", clean_title).strip()
    clean_author = re.sub(r"[^a-z0-9\s]", " ", (author or "").lower())
    clean_author = re.sub(r"\s+", " ", clean_author).strip()
    return f"{clean_title}|{clean_author}"


def _pick_quick_shelf(shelves: list[dict[str, Any]]) -> Optional[dict[str, Any]]:
    best: Optional[dict[str, Any]] = None
    best_score = 0
    for shelf in shelves:
        videos = shelf.get("videos", [])
        if not videos:
            continue
        score = _quick_score(_first_non_empty(shelf.get("title")))
        if score > best_score:
            best_score = score
            best = shelf
    if best is not None:
        return best
    for shelf in shelves:
        if len(shelf.get("videos", [])) >= 8:
            return shelf
    for shelf in shelves:
        if shelf.get("videos"):
            return shelf
    return None


def _clean_payload(payload: dict[str, Any], max_videos: int) -> dict[str, Any]:
    shelves = payload.get("shelves")
    if not isinstance(shelves, list):
        shelves = []
    clean_shelves: list[dict[str, Any]] = []
    for raw_shelf in shelves:
        if not isinstance(raw_shelf, dict):
            continue
        title = _first_non_empty(raw_shelf.get("title"))
        if not title:
            continue
        subtitle = _first_non_empty(raw_shelf.get("subtitle"))
        clean_videos: list[dict[str, Any]] = []
        seen_ids: set[str] = set()
        for raw_video in raw_shelf.get("videos", []):
            if not isinstance(raw_video, dict):
                continue
            video_id = _first_non_empty(raw_video.get("id") or raw_video.get("videoId"))
            video_title = _first_non_empty(raw_video.get("title"))
            if not video_id or not video_title or video_id in seen_ids:
                continue
            seen_ids.add(video_id)
            clean_videos.append(
                {
                    "id": video_id,
                    "title": video_title,
                    "author": _first_non_empty(
                        raw_video.get("author") or raw_video.get("artist")
                    ),
                    "durationSecs": raw_video.get("durationSecs"),
                    "thumbnail": _first_non_empty(raw_video.get("thumbnail")),
                }
            )
            if len(clean_videos) >= max_videos:
                break
        if not clean_videos:
            continue
        clean_shelves.append(
            {
                "title": title,
                "subtitle": subtitle,
                "videos": clean_videos,
                "mixes": [],
            }
        )
    quick_shelf = _pick_quick_shelf(clean_shelves)
    quick_picks: list[dict[str, Any]] = []
    if quick_shelf:
        seen_ids: set[str] = set()
        seen_signatures: set[str] = set()
        for video in quick_shelf.get("videos", []):
            if not isinstance(video, dict):
                continue
            video_id = _first_non_empty(video.get("id"))
            if not video_id or video_id in seen_ids:
                continue
            signature = _track_signature(
                _first_non_empty(video.get("title")),
                _first_non_empty(video.get("author")),
            )
            if not signature or signature in seen_signatures:
                continue
            seen_ids.add(video_id)
            seen_signatures.add(signature)
            quick_picks.append(video)
            if len(quick_picks) >= 15:
                break
    quick_label = (
        _first_non_empty(quick_shelf.get("subtitle"))
        if quick_shelf
        else "From your YouTube Music Quick Picks"
    )
    if not quick_label:
        quick_label = (
            _first_non_empty(quick_shelf.get("title"))
            if quick_shelf
            else "From your YouTube Music Quick Picks"
        )
    return {
        "shelves": clean_shelves,
        "quickPicks": quick_picks,
        "quickPicksLabel": quick_label,
        "quickPicksFromOfficialShelf": bool(
            quick_shelf and _quick_score(_first_non_empty(quick_shelf.get("title"))) > 0
        ),
    }


PLAYWRIGHT_EXTRACT_JS = """
(opts) => {
  const maxShelves = Math.max(1, Math.min(opts?.maxShelves ?? 18, 50));
  const maxVideosPerShelf = Math.max(1, Math.min(opts?.maxVideosPerShelf ?? 24, 100));
  const root = window.ytInitialData || window.ytcfg?.data_?.INITIAL_DATA;
  if (!root) return { shelves: [] };

  const textValue = (node) => {
    if (!node) return '';
    if (typeof node === 'string') return node.trim();
    if (Array.isArray(node)) {
      return node.map((x) => textValue(x)).filter(Boolean).join(' ').trim();
    }
    if (typeof node === 'object') {
      if (typeof node.text === 'string') return node.text.trim();
      if (Array.isArray(node.runs)) {
        return node.runs.map((x) => textValue(x)).filter(Boolean).join(' ').trim();
      }
      if (typeof node.simpleText === 'string') return node.simpleText.trim();
    }
    return '';
  };

  const pickThumb = (renderer) => {
    const thumbs =
      renderer?.thumbnailRenderer?.musicThumbnailRenderer?.thumbnail?.thumbnails ||
      renderer?.thumbnail?.musicThumbnailRenderer?.thumbnail?.thumbnails ||
      renderer?.thumbnail?.thumbnails ||
      [];
    if (!Array.isArray(thumbs) || !thumbs.length) return '';
    return thumbs[thumbs.length - 1]?.url || '';
  };

  const videoIdFor = (renderer) =>
    renderer?.overlay?.musicItemThumbnailOverlayRenderer?.content?.musicPlayButtonRenderer?.playNavigationEndpoint?.watchEndpoint?.videoId ||
    renderer?.navigationEndpoint?.watchEndpoint?.videoId ||
    renderer?.title?.runs?.[0]?.navigationEndpoint?.watchEndpoint?.videoId ||
    renderer?.flexColumns?.[0]?.musicResponsiveListItemFlexColumnRenderer?.text?.runs?.find((run) => run?.navigationEndpoint?.watchEndpoint?.videoId)?.navigationEndpoint?.watchEndpoint?.videoId ||
    '';

  const titleFor = (renderer) =>
    textValue(renderer?.title) ||
    textValue(renderer?.flexColumns?.[0]?.musicResponsiveListItemFlexColumnRenderer?.text) ||
    '';

  const artistFor = (renderer) =>
    textValue(renderer?.subtitle) ||
    textValue(renderer?.flexColumns?.[1]?.musicResponsiveListItemFlexColumnRenderer?.text) ||
    '';

  const durationFor = (renderer) => {
    const raw =
      textValue(renderer?.fixedColumns?.[0]?.musicResponsiveListItemFixedColumnRenderer?.text) ||
      textValue(renderer?.lengthText);
    if (!raw) return null;
    const parts = raw.split(':').map((p) => parseInt(p, 10)).filter((v) => !Number.isNaN(v));
    if (parts.length === 2) return parts[0] * 60 + parts[1];
    if (parts.length === 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
    return null;
  };

  const videoFor = (raw) => {
    const renderer = raw?.musicTwoRowItemRenderer || raw?.musicResponsiveListItemRenderer;
    if (!renderer) return null;
    const id = videoIdFor(renderer);
    const title = titleFor(renderer);
    if (!id || !title) return null;
    return {
      id,
      title,
      author: artistFor(renderer),
      durationSecs: durationFor(renderer),
      thumbnail: pickThumb(renderer),
    };
  };

  const shelves = [];
  const seenShelves = new Set();
  const addShelf = (renderer, kind) => {
    if (!renderer) return;
    const title =
      kind === 'carousel'
        ? textValue(renderer?.header?.musicCarouselShelfBasicHeaderRenderer?.title)
        : textValue(renderer?.title) ||
          textValue(renderer?.header?.musicResponsiveHeaderRenderer?.title) ||
          textValue(renderer?.header?.musicCarouselShelfBasicHeaderRenderer?.title);
    const subtitle =
      textValue(renderer?.header?.musicCarouselShelfBasicHeaderRenderer?.strapline) ||
      textValue(renderer?.subtitle) ||
      '';
    const items = Array.isArray(renderer?.contents) ? renderer.contents : [];
    const videos = [];
    const seenVideos = new Set();
    for (const item of items) {
      const video = videoFor(item);
      if (!video || seenVideos.has(video.id)) continue;
      seenVideos.add(video.id);
      videos.push(video);
      if (videos.length >= maxVideosPerShelf) break;
    }
    const shelfKey = `${kind}:${(title || '').toLowerCase()}:${videos.length}`;
    if (!title || !videos.length || seenShelves.has(shelfKey)) return;
    seenShelves.add(shelfKey);
    shelves.push({ title, subtitle, videos, mixes: [] });
    if (shelves.length >= maxShelves) return;
  };

  const walk = (node, depth = 0) => {
    if (!node || depth > 20 || shelves.length >= maxShelves) return;
    if (Array.isArray(node)) {
      for (const item of node) walk(item, depth + 1);
      return;
    }
    if (typeof node !== 'object') return;
    if (node.musicCarouselShelfRenderer) {
      addShelf(node.musicCarouselShelfRenderer, 'carousel');
    }
    if (node.musicShelfRenderer) {
      addShelf(node.musicShelfRenderer, 'shelf');
    }
    for (const value of Object.values(node)) {
      walk(value, depth + 1);
      if (shelves.length >= maxShelves) break;
    }
  };

  walk(root);
  return { shelves };
}
"""


async def _fetch_with_playwright(req: HomeRequest) -> dict[str, Any]:
    cookies = _parse_cookie_header(req.cookie)
    if not cookies:
        raise HTTPException(status_code=400, detail="Cookie header is required")

    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=True,
            args=["--disable-dev-shm-usage", "--no-sandbox"],
        )
        context = await browser.new_context(
            user_agent=WEB_UA,
            locale=req.hl or "en",
            viewport={"width": 1366, "height": 820},
        )
        try:
            cookie_payload = [
                {
                    "name": name,
                    "value": value,
                    "domain": "music.youtube.com",
                    "path": "/",
                    "secure": True,
                    "httpOnly": False,
                    "sameSite": "Lax",
                }
                for name, value in cookies.items()
            ]
            await context.add_cookies(cookie_payload)

            page = await context.new_page()
            target = (
                "https://music.youtube.com/"
                f"?authuser={_normalize_auth_user(req.authUser)}"
                f"&hl={(req.hl or 'en').strip()}"
                f"&gl={(req.gl or 'IN').strip()}"
            )
            await page.goto(target, wait_until="domcontentloaded", timeout=16000)
            await page.wait_for_timeout(1800)
            raw_payload = await page.evaluate(
                PLAYWRIGHT_EXTRACT_JS,
                {
                    "maxShelves": req.maxShelves,
                    "maxVideosPerShelf": req.maxVideosPerShelf,
                },
            )
            if not isinstance(raw_payload, dict):
                raw_payload = {"shelves": []}
            clean = _clean_payload(raw_payload, req.maxVideosPerShelf)
            clean["backend"] = "playwright"
            return clean
        finally:
            await context.close()
            await browser.close()


def _fetch_with_ytmusicapi(req: HomeRequest) -> dict[str, Any]:
    if YTMusic is None:
        raise RuntimeError("ytmusicapi is not installed")

    if req.ytmusicAuth:
        ytm = YTMusic(auth=req.ytmusicAuth)
    else:
        ytm = YTMusic()
    raw_home = ytm.get_home(limit=req.maxShelves)
    shelves: list[dict[str, Any]] = []
    for section in raw_home or []:
        if not isinstance(section, dict):
            continue
        title = _first_non_empty(section.get("title"))
        if not title:
            continue
        subtitle = _first_non_empty(section.get("subtitle"))
        videos: list[dict[str, Any]] = []
        seen_ids: set[str] = set()
        for item in section.get("contents", []) or []:
            if not isinstance(item, dict):
                continue
            video_id = _first_non_empty(item.get("videoId"))
            video_title = _first_non_empty(item.get("title"))
            if not video_id or not video_title or video_id in seen_ids:
                continue
            seen_ids.add(video_id)
            artists = item.get("artists") or []
            author = ""
            if isinstance(artists, list) and artists:
                first_artist = artists[0]
                if isinstance(first_artist, dict):
                    author = _first_non_empty(first_artist.get("name"))
            videos.append(
                {
                    "id": video_id,
                    "title": video_title,
                    "author": author,
                    "durationSecs": item.get("duration_seconds"),
                }
            )
            if len(videos) >= req.maxVideosPerShelf:
                break
        if videos:
            shelves.append(
                {
                    "title": title,
                    "subtitle": subtitle,
                    "videos": videos,
                    "mixes": [],
                }
            )
    clean = _clean_payload({"shelves": shelves}, req.maxVideosPerShelf)
    clean["backend"] = "ytmusicapi"
    return clean


def _validate_api_key(x_api_key: Optional[str]) -> None:
    if not API_KEY:
        return
    if (x_api_key or "").strip() != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid API key")


def _extract_audio_stream_info(
    video_id: str,
    raw_cookie: Optional[str] = None,
) -> dict[str, Any]:
    if yt_dlp is None:
        raise RuntimeError("yt-dlp is not installed")
    cached = _AUDIO_URL_CACHE.get(video_id)
    now = time.time()
    if cached is not None and cached[1] > now:
        return cached[0]

    watch_url = f"https://www.youtube.com/watch?v={video_id}"
    cookie = (raw_cookie or "").strip() or AUDIO_COOKIE
    base_opts = {
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "skip_download": True,
        "format": "bestaudio[ext=m4a]/bestaudio",
    }
    if cookie:
        base_opts["http_headers"] = {
            "Cookie": cookie,
            "Origin": "https://music.youtube.com",
            "Referer": "https://music.youtube.com/",
            "User-Agent": WEB_UA,
        }

    attempts = [
        {
            **base_opts,
            "extractor_args": {
                "youtube": {"player_client": ["android_music", "android"]}
            },
        },
        {
            **base_opts,
            "extractor_args": {
                "youtube": {"player_client": ["tv_embedded", "android_creator", "web"]}
            },
        },
        base_opts,
    ]

    last_error: Optional[Exception] = None
    for ydl_opts in attempts:
        try:
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                info = ydl.extract_info(watch_url, download=False)
            audio_url = (info or {}).get("url") if isinstance(info, dict) else None
            if not audio_url:
                raise RuntimeError("No playable audio URL found")
            stream_headers = (
                (info or {}).get("http_headers") if isinstance(info, dict) else None
            )
            if not isinstance(stream_headers, dict):
                stream_headers = {}
            clean_headers = {
                str(key): str(value)
                for key, value in stream_headers.items()
                if key and value
            }
            stream_info = {
                "url": audio_url,
                "headers": clean_headers,
            }
            _AUDIO_URL_CACHE[video_id] = (stream_info, now + _AUDIO_URL_TTL_SECONDS)
            return stream_info
        except Exception as exc:
            last_error = exc

    raise RuntimeError(f"Could not resolve playable audio: {last_error}")


def _extract_audio_url(video_id: str) -> str:
    return _extract_audio_stream_info(video_id)["url"]


def _has_cached_audio_url(video_id: str) -> bool:
    cached = _AUDIO_URL_CACHE.get(video_id)
    return bool(cached is not None and cached[1] > time.time())


app = FastAPI(title=APP_TITLE, version="1.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/")
@app.get("/health")
@app.get("/healthz")
async def healthz() -> dict[str, Any]:
    return {"ok": True, "service": APP_TITLE}


@app.head("/")
@app.head("/health")
@app.head("/healthz")
async def healthz_head() -> Response:
    return Response(status_code=200)


@app.post("/ytmusic/home")
async def ytmusic_home(
    req: HomeRequest,
    x_api_key: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    _validate_api_key(x_api_key)
    strategy = (req.strategy or "playwright").strip().lower()
    if strategy == "ytmusicapi":
        try:
            data = await asyncio.to_thread(_fetch_with_ytmusicapi, req)
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"ytmusicapi failed: {e}") from e
    else:
        try:
            data = await _fetch_with_playwright(req)
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"playwright failed: {e}") from e

    return {
        "ok": True,
        "backend": data.get("backend", strategy),
        "quickPicks": data.get("quickPicks", []),
        "quickPicksLabel": data.get("quickPicksLabel", "From your YouTube Music Quick Picks"),
        "quickPicksFromOfficialShelf": bool(data.get("quickPicksFromOfficialShelf")),
        "shelves": data.get("shelves", []),
    }


@app.get("/ytmusic/resolve/{video_id}")
async def ytmusic_resolve(
    video_id: str,
    x_api_key: Optional[str] = Header(default=None),
    x_ytmusic_cookie: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    _validate_api_key(x_api_key)
    video_id = (video_id or "").strip()
    if not video_id:
        raise HTTPException(status_code=400, detail="video_id is required")

    was_cached = _has_cached_audio_url(video_id)
    try:
        await asyncio.to_thread(_extract_audio_stream_info, video_id, x_ytmusic_cookie)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"audio resolve failed: {e}") from e

    return {
        "ok": True,
        "videoId": video_id,
        "cached": was_cached,
        "ttlSeconds": _AUDIO_URL_TTL_SECONDS,
    }


@app.get("/ytmusic/stream/{video_id}")
async def ytmusic_stream(
    video_id: str,
    range_header: Optional[str] = Header(default=None, alias="Range"),
    x_api_key: Optional[str] = Header(default=None),
    x_ytmusic_cookie: Optional[str] = Header(default=None),
):
    _validate_api_key(x_api_key)
    video_id = (video_id or "").strip()
    if not video_id:
        raise HTTPException(status_code=400, detail="video_id is required")

    try:
        stream_info = await asyncio.to_thread(
            _extract_audio_stream_info,
            video_id,
            x_ytmusic_cookie,
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"audio resolve failed: {e}") from e
    audio_url = str(stream_info.get("url") or "").strip()
    upstream_headers = stream_info.get("headers")
    if not audio_url:
        raise HTTPException(status_code=502, detail="audio resolve failed: empty url")
    if not isinstance(upstream_headers, dict):
        upstream_headers = {}

    req_headers = {
        "Accept": "*/*",
    }
    for header_name in ("User-Agent", "Referer", "Origin", "Cookie"):
        header_value = upstream_headers.get(header_name)
        if header_value:
            req_headers[header_name] = str(header_value)
    if "User-Agent" not in req_headers:
        req_headers["User-Agent"] = WEB_UA
    if range_header:
        req_headers["Range"] = range_header

    timeout = httpx.Timeout(20.0, read=45.0)
    client = httpx.AsyncClient(follow_redirects=True, timeout=timeout)
    upstream = await client.stream("GET", audio_url, headers=req_headers).__aenter__()
    if upstream.status_code >= 400:
        try:
            text = await upstream.aread()
        finally:
            await upstream.aclose()
            await client.aclose()
        raise HTTPException(
            status_code=502,
            detail=(
                f"upstream error {upstream.status_code}: "
                f"{text[:200].decode('utf-8', errors='ignore')}"
            ),
        )

    response_headers = {"Accept-Ranges": upstream.headers.get("accept-ranges", "bytes")}
    for header_name in (
        "content-type",
        "content-length",
        "content-range",
        "cache-control",
        "etag",
        "last-modified",
    ):
        header_value = upstream.headers.get(header_name)
        if header_value:
            response_headers[header_name] = header_value

    async def _iter_bytes():
        try:
            async for chunk in upstream.aiter_bytes():
                yield chunk
        finally:
            await upstream.aclose()
            await client.aclose()

    return StreamingResponse(
        _iter_bytes(),
        status_code=upstream.status_code,
        headers=response_headers,
        media_type=upstream.headers.get("content-type"),
    )
