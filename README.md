# Coastal Proximity Check

Flags Florida and Texas property addresses as **COASTAL** if within 2 miles of the open ocean coastline, while also exposing nearby bay / lagoon shoreline candidates for advisor review.

- **Data**: US Census Bureau TIGER/Line 2023 National Coastline (L4150) — official government source
- **Scope**: Florida (Gulf + Atlantic) and Texas (Gulf) only
- **What counts as coast**: Ocean-facing shoreline only for the official result, with advisor context for bay / lagoon shoreline candidates; Tampa Bay and the Fort Myers-side open-water approach are now included in the primary open-water set
- **Stack**: Ruby + Sinatra — runs as a web app or JSON API

---

## Setup (one-time)

**1. Install Ruby gems**
```bash
bundle install --path vendor/bundle
```

**2. Download and process NOAA coastline data**
```bash
bundle exec ruby bin/setup_coastline.rb
```
This downloads the Census TIGER/Line coastline shapefile (~16 MB), filters it to FL/TX outer coast, splits bay / lagoon shoreline candidates into a second layer, and validates against 12 known test addresses. Output: `data/coastline.geojson` and `data/interior_water.geojson`.

**3. Set your Google Maps API key**
```bash
export GOOGLE_MAPS_BROWSER_KEY=your_browser_key
export GOOGLE_MAPS_SERVER_KEY=your_server_key
```
The browser key loads Google Maps JS in the page, and the server key is used only for geocoding. For local testing you can set `GOOGLE_MAPS_API_KEY` as a legacy fallback, but production should use the split keys.

**4. Start the app**
```bash
bundle exec ruby app.rb
# → http://localhost:4567
```

**5. Run the bug checker**
```bash
bundle exec ruby bin/bug_check.rb
```
This runs 5 quick sanity checks against the local decision logic so you can catch classification regressions before shipping.

**6. Run the deploy smoke test**
```bash
bundle exec ruby bin/deploy_smoke_test.rb
```
This checks the home page, both overlay endpoints, and the local decision API. Set `SMOKE_ADDRESS` if you want to include one live geocoded search in the check.

---

## Usage

### Web UI
Open `http://localhost:4567` and enter any FL or TX property address.

The map now:
- Pins the searched property address
- Draws a direct line to the nearest official open-ocean coastline
- Lets advisors turn on bay / lagoon shoreline candidates as a separate layer
- Updates the open-coast and bay overlay layers separately from the local drag/drop flow

Only address search hits Google geocoding. Dragging a pin and toggling overlays stay local and do not call Google.

### JSON API (for salesapp integration)
```
GET /api/check?address=123+Ocean+Dr+Miami+FL+33139
```

**Response:**
```json
{
  "result": "COASTAL",
  "reason": "0.19 miles from ocean coastline — flag for valuation review",
  "address": "123 Ocean Dr, Miami FL 33139",
  "lat": 25.7902,
  "lng": -80.1300,
  "distance_mi": 0.19,
  "coastline_point": { "lat": 25.7899, "lng": -80.1288 },
  "interior_distance_mi": 1.42,
  "interior_point": { "lat": 25.7761, "lng": -80.1622 }
}
```

**Result values:**

| Value | Meaning |
|---|---|
| `COASTAL` | Within 2 miles of ocean coast — flag for valuation review |
| `NOT_COASTAL` | More than 2 miles from ocean coast |
| `OUT_OF_AREA` | Address is outside FL or TX |
| `UNKNOWN` | Geocoding failed (bad address or missing API key) |

---

## Deploy

```bash
# Build the Docker image; it now generates coastline data during the build
docker build -t coastal-check .
docker run -p 4567:4567 \
  -e GOOGLE_MAPS_BROWSER_KEY=your_browser_key \
  -e GOOGLE_MAPS_SERVER_KEY=your_server_key \
  coastal-check
```

Recommended free hosting options:
- [Google Cloud Run](https://cloud.google.com/run/) for the cleanest container-based deployment
- [Oracle Cloud Always Free](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm) if you want an always-on VM
- [Render free web services](https://render.com/docs/free) only for demos, not production
- [Railway pricing](https://docs.railway.com/pricing) is not a good free production option

Set the split Google keys in your deployment environment. The coastline data is generated during the Docker build, so there is no separate preprocessing step to remember.

---

## How it works

```
Address
  → Google Geocoding API    → lat / lng
  → Service area check      → Must be in FL or TX bounding box
  → Local distance calc     → Nearest ocean coastline segment (miles)
  → Threshold check         → < 2 miles → COASTAL
```

**Coastline data**: Census TIGER/Line L4150 "Coastline" features named "Atlantic" and "Gulf", clipped to the FL/TX region and split through 16 bay exclusion zones into two layers:
- `data/coastline.geojson`: official open-ocean coastline used for the primary `COASTAL` / `NOT_COASTAL` decision
- `data/interior_water.geojson`: interior bay / lagoon candidate shoreline used as an advisor overlay and alternate measurement seed

**Bay exclusions**: Indian River Lagoon, Biscayne Bay, Florida Bay, Apalachee Bay, Choctawhatchee Bay, Pensacola Bay, Galveston Bay, Matagorda Bay, San Antonio Bay, Aransas Bay, Corpus Christi Bay, Laguna Madre, and others. Tampa Bay and the Charlotte Harbor / Fort Myers-side open-water path are intentionally included in the primary open-water layer. See `bin/setup_coastline.rb` for the full list and coordinate bounds.

**Distance calculation**: Pure-Ruby point-to-line-segment haversine, run against all 124K coastline segments. No external GIS dependencies.

**Usage note**: At the current workflow, only address searches call Google. Drag/drop and overlay toggles are local geometry and map-layer updates, so low daily usage should remain very modest.

**Known data gap**: Census TIGER L4150 has sparse coverage of North Padre Island Gulf coast (~26.2°N–27.5°N). Properties in this area may show larger-than-expected distances. South Padre Island and the Corpus Christi area are well-covered.

---

## Refresh coastline data

The Census releases updated TIGER/Line files annually. To update:
1. Edit `CENSUS_URL` in `bin/setup_coastline.rb` to point to the new year (e.g., `TIGER2024`)
2. Delete `data/coastline.geojson`
3. Re-run `bundle exec ruby bin/setup_coastline.rb`
