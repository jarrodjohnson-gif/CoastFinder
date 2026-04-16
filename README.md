# CoastFinder — Installation & Operations Guide

Returns **YES** or **NO** for the field "Within 2 miles of Coast?" on Florida property addresses.
Returns a JSON result for salesapp integration or renders a map UI for manual lookups.

---

## How It Works

```
Address input
  └─► Google Geocoding API          (server-side, GOOGLE_MAPS_SERVER_KEY)
        └─► lat / lng coordinates
              └─► FL bounding box check
                    └─► Point-to-segment distance scan
                          └─► Nearest coastline segment (miles)
                                └─► < 2 miles → YES (flagged)
                                    ≥ 2 miles → NO
```

**Coastline data** is built once from US Census TIGER/Line shapefiles (not live — no GIS service dependency):
- `data/coastline.geojson` — open-ocean coastline used for the YES/NO decision
- `data/interior_water.geojson` — bay/lagoon candidates shown as an advisor overlay only

The map UI loads Google Maps in the browser (GOOGLE_MAPS_BROWSER_KEY). Address search calls Google
Geocoding on the server. Drag-and-drop and overlay toggles are local geometry — no API calls.

---

## Prerequisites

### 1. Ruby

Requires **Ruby 2.6 or higher**. Ruby 3.2 is recommended (matches the Dockerfile).

Check your version:
```bash
ruby --version
```

If Ruby is not installed:
- **macOS**: `brew install ruby` (Homebrew) or use [rbenv](https://github.com/rbenv/rbenv)
- **Linux**: `sudo apt-get install ruby-full` or use rbenv
- **Docker**: skip this — the Dockerfile handles it

### 2. Bundler

```bash
gem install bundler
```

Verify: `bundle --version` (any version works)

### 3. System packages

Required for native gem compilation and Census shapefile extraction:

**macOS:**
```bash
xcode-select --install   # build tools
brew install unzip       # already present on most systems
```

**Ubuntu / Debian:**
```bash
sudo apt-get update && sudo apt-get install -y build-essential unzip
```

**Docker:** included automatically via the Dockerfile.

### 4. Google Maps API key

You need **one API key** (or two separate keys — one for the browser, one for the server).

**APIs that must be enabled** in [Google Cloud Console](https://console.cloud.google.com/apis/library):
- Maps JavaScript API
- Geocoding API

**Billing must be active.** Both APIs require a billing account even within the free tier.
Maps JavaScript API will return `InvalidKeyMapError` in the browser if billing is inactive.

**HTTP referrer restrictions** (if you have them set on your key):
- For local development, add `http://localhost:4567/*` to the allowed referrers
- For production, add your deployment domain (e.g. `https://your-app.railway.app/*`)
- If no referrer restrictions are set, the key works anywhere — fine for internal tools

---

## Local Installation

### Step 1 — Clone the repo

```bash
git clone https://github.com/jarrodjohnson-gif/CoastFinder.git
cd CoastFinder
```

### Step 2 — Install Ruby gems

```bash
bundle install
```

This installs Sinatra, Puma, HTTParty, and JSON into `vendor/bundle`.
Expect 30–60 seconds on first run (compiles native extensions).

### Step 3 — Build coastline data (one-time)

```bash
bundle exec ruby bin/setup_coastline.rb
```

**What this does:**
1. Downloads the US Census TIGER/Line 2023 National Coastline shapefile (~16 MB) from `census.gov`
2. Downloads AREAWATER county shapefiles for 8 FL counties (~2 MB each) from `census.gov`
3. Parses the raw binary shapefiles in pure Ruby — no GDAL or PostGIS required
4. Filters to FL outer coast (Atlantic + Gulf named features only)
5. Applies 17 bay exclusion zones to strip inner lagoon/estuary segments
6. Adds AREAWATER H2051 bay polygon boundaries for Charlotte Harbor, Tampa Bay, Biscayne Bay, etc.
7. Validates against 13 known test coordinates (all must pass before writing output)
8. Writes `data/coastline.geojson` and `data/interior_water.geojson`

**Expected output:**
```
All validation checks passed.
Total AREAWATER features added: 1300
Segments: 1851
```

**Runtime:** 60–180 seconds depending on internet speed (Census downloads cached after first run).

**Cached downloads:** Raw shapefiles are cached in `/tmp`. Re-running the script skips downloads
and only re-processes the data (takes ~10 seconds). To force a full re-download, delete the
cached files: `rm /tmp/tl_2023_*.shp /tmp/tl_2023_*.zip`

### Step 4 — Set environment variables

```bash
export GOOGLE_MAPS_BROWSER_KEY=AIza...   # loaded by the browser to render the map
export GOOGLE_MAPS_SERVER_KEY=AIza...    # used server-side for geocoding only
```

Both can be the same key for a simple setup. Using split keys lets you apply separate
HTTP referrer restrictions — browser key locked to your domain, server key locked to
your server's IP.

### Step 5 — Start the server

**Development (single process):**
```bash
bundle exec ruby app.rb
```

**Production (Puma, 2 workers × 4 threads — use this for any shared/deployed environment):**
```bash
bundle exec puma -C config/puma.rb
```

App is available at `http://localhost:4567`

Verify it started correctly:
```bash
curl http://localhost:4567/health
# → {"ok":true,"segments":435896,"version":"..."}
```

The `segments` count should be above 400,000. If it shows a low number or the health check
fails, the coastline data was not built correctly — re-run Step 3.

---

## Verify the Installation

Run the full accuracy test (no API key required — tests local geometry only):
```bash
bundle exec ruby bin/accuracy_test.rb
```

Expected result: `PASSED 61 | FAILED 0`

Run the smoke test against the live server (requires server running on :4567):
```bash
bundle exec ruby bin/deploy_smoke_test.rb
```

---

## API Reference

### Check an address
```
GET /api/check?address=123+Ocean+Dr+Miami+Beach+FL+33139
```

Requires `GOOGLE_MAPS_SERVER_KEY` set. Geocodes the address, then runs the distance check.

**Response:**
```json
{
  "result": "YES",
  "reason": "0.19 miles from ocean coastline — flag for valuation review",
  "address": "123 Ocean Dr, Miami Beach FL 33139",
  "lat": 25.7902,
  "lng": -80.1300,
  "distance_mi": 0.19,
  "coastline_point": { "lat": 25.7899, "lng": -80.1288 },
  "interior_distance_mi": 1.42,
  "interior_point": { "lat": 25.7761, "lng": -80.1622 }
}
```

### Check coordinates directly (no geocoding)
```
GET /api/check_coords?lat=25.7902&lng=-80.1300
```

No API key required. Useful for testing or when you already have lat/lng.

### Result values

| Value | Meaning |
|---|---|
| `YES` | Within 2 miles of coast — flagged for valuation review |
| `NO` | More than 2 miles from coast — no flag needed |
| `OUT_OF_AREA` | Address is outside FL service area |
| `UNKNOWN` | Geocoding failed (bad address or missing/invalid API key) |

### Health check
```
GET /health
→ {"ok":true,"segments":435896,"version":"1776370273"}
```

---

## Docker Deployment

The Dockerfile builds coastline data at image build time — no setup step needed after deploy.

```bash
# Build (includes Census data download — takes 3–5 min)
docker build -t coastfinder .

# Run
docker run -p 4567:4567 \
  -e GOOGLE_MAPS_BROWSER_KEY=AIza... \
  -e GOOGLE_MAPS_SERVER_KEY=AIza... \
  coastfinder
```

To scale concurrency, pass Puma env vars:
```bash
docker run -p 4567:4567 \
  -e GOOGLE_MAPS_BROWSER_KEY=AIza... \
  -e GOOGLE_MAPS_SERVER_KEY=AIza... \
  -e WEB_CONCURRENCY=4 \
  -e RAILS_MAX_THREADS=8 \
  coastfinder
```

Default is 2 workers × 4 threads.

---

## Updating Coastline Data

Census releases updated TIGER/Line files each year. To update:

1. Edit `CENSUS_URL` in `bin/setup_coastline.rb`:
   ```ruby
   CENSUS_URL = 'https://www2.census.gov/geo/tiger/TIGER2024/COASTLINE/tl_2024_us_coastline.zip'
   ```
2. Delete cached shapefiles: `rm /tmp/tl_2023_*.shp /tmp/tl_2023_*.zip`
3. Re-run setup: `bundle exec ruby bin/setup_coastline.rb`
4. Verify: `bundle exec ruby bin/accuracy_test.rb`

---

## Troubleshooting

**`InvalidKeyMapError` in browser console / map won't load**
- Maps JavaScript API is not enabled for your key, or billing is not active
- Go to [console.cloud.google.com/apis/library](https://console.cloud.google.com/apis/library), enable "Maps JavaScript API"
- Ensure a billing account is linked to the project

**`RefererNotAllowedMapError` in browser console**
- Your key has HTTP referrer restrictions set and `localhost` is not in the allowed list
- Add `http://localhost:4567/*` in Cloud Console → Credentials → your key → Application restrictions

**Address search returns `UNKNOWN`**
- `GOOGLE_MAPS_SERVER_KEY` is not set or is wrong
- Geocoding API is not enabled for that key
- Verify: `curl "https://maps.googleapis.com/maps/api/geocode/json?address=Miami+FL&key=YOUR_KEY"`

**`/health` returns low segment count or connection refused**
- Coastline data not built — run `bundle exec ruby bin/setup_coastline.rb`
- Server not started — run `bundle exec puma -C config/puma.rb`

**`bundle install` fails with native extension error**
- Missing build tools — run `xcode-select --install` (macOS) or `apt-get install build-essential` (Linux)
