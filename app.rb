require 'sinatra'
require 'httparty'
require 'json'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
LEGACY_GOOGLE_MAPS_KEY = ENV['GOOGLE_MAPS_API_KEY'].to_s.strip
GOOGLE_MAPS_BROWSER_KEY = ENV['GOOGLE_MAPS_BROWSER_KEY'].to_s.strip
GOOGLE_MAPS_SERVER_KEY  = ENV['GOOGLE_MAPS_SERVER_KEY'].to_s.strip
COASTAL_RADIUS_MI = 2.0

warn 'WARN: Set GOOGLE_MAPS_BROWSER_KEY and GOOGLE_MAPS_SERVER_KEY separately for production; GOOGLE_MAPS_API_KEY is a legacy fallback.' if GOOGLE_MAPS_BROWSER_KEY.empty? || GOOGLE_MAPS_SERVER_KEY.empty?

FL_BOUNDS = { lat: [24.3, 31.1], lng: [-87.7, -79.8] }.freeze
TX_BOUNDS = { lat: [25.7, 30.2], lng: [-97.5, -93.5] }.freeze

helpers do
  def google_maps_browser_key
    GOOGLE_MAPS_BROWSER_KEY.empty? ? LEGACY_GOOGLE_MAPS_KEY : GOOGLE_MAPS_BROWSER_KEY
  end

  def google_maps_server_key
    GOOGLE_MAPS_SERVER_KEY.empty? ? LEGACY_GOOGLE_MAPS_KEY : GOOGLE_MAPS_SERVER_KEY
  end
end

# ---------------------------------------------------------------------------
# Coastline data (loaded once at startup)
# ---------------------------------------------------------------------------
COASTLINE_FILE = File.join(__dir__, 'data', 'coastline.geojson')
INTERIOR_WATER_FILE = File.join(__dir__, 'data', 'interior_water.geojson')

def load_segments(path, label)
  unless File.exist?(path)
    warn "WARN: #{path} not found. Run bin/setup_coastline.rb first."
    return nil
  end
  data = JSON.parse(File.read(path))
  segments = []
  data['features'].each do |feature|
    geom = feature['geometry']
    next unless geom
    lines = case geom['type']
            when 'LineString'      then [geom['coordinates']]
            when 'MultiLineString' then geom['coordinates']
            else next
            end
    lines.each { |l| l.each_cons(2) { |a, b| segments << [a[1], a[0], b[1], b[0]] } }
  end
  warn "Loaded #{segments.size} #{label} segments."
  segments
end

COASTLINE_SEGMENTS      = load_segments(COASTLINE_FILE, 'open-coast')
INTERIOR_WATER_SEGMENTS = load_segments(INTERIOR_WATER_FILE, 'interior-water')

# ---------------------------------------------------------------------------
# Spatial grid index — avoids brute-forcing all 339K segments per request.
# Divides the FL/TX bounding box into ~0.5° cells. Each segment is registered
# in every cell its bounding box touches. A lookup returns only the candidate
# segments for the cells near the query point.
# ---------------------------------------------------------------------------
GRID_CELL = 0.5  # degrees (~35 miles) — coarse enough to be fast, fine enough to be selective

def build_grid_index(segments)
  idx = Hash.new { |h, k| h[k] = [] }
  segments.each_with_index do |(alat, alng, blat, blng), i|
    min_row = ((([alat, blat].min - GRID_CELL) / GRID_CELL).floor)
    max_row = ((([alat, blat].max + GRID_CELL) / GRID_CELL).ceil)
    min_col = ((([alng, blng].min - GRID_CELL) / GRID_CELL).floor)
    max_col = ((([alng, blng].max + GRID_CELL) / GRID_CELL).ceil)
    (min_row..max_row).each { |r| (min_col..max_col).each { |c| idx[[r, c]] << i } }
  end
  idx
end

def candidates(lat, lng, segments, index)
  row = (lat / GRID_CELL).floor
  col = (lng / GRID_CELL).floor
  seen = {}
  result = []
  (-1..1).each do |dr|
    (-1..1).each do |dc|
      (index[[row + dr, col + dc]] || []).each do |i|
        next if seen[i]
        seen[i] = true
        result << segments[i]
      end
    end
  end
  result
end

COASTLINE_INDEX      = COASTLINE_SEGMENTS      ? build_grid_index(COASTLINE_SEGMENTS)      : {}
INTERIOR_WATER_INDEX = INTERIOR_WATER_SEGMENTS ? build_grid_index(INTERIOR_WATER_SEGMENTS) : {}

# Versioned GeoJSON etag — computed once at startup from file mtime so the
# browser can cache the overlay aggressively and only re-fetch when rebuilt.
COASTLINE_VERSION      = File.exist?(COASTLINE_FILE)      ? File.mtime(COASTLINE_FILE).to_i.to_s      : '0'
INTERIOR_WATER_VERSION = File.exist?(INTERIOR_WATER_FILE) ? File.mtime(INTERIOR_WATER_FILE).to_i.to_s : '0'

# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------
def point_to_segment_projection(plat, plng, alat, alng, blat, blng)
  buf = 0.04
  return Float::INFINITY unless plat.between?([alat, blat].min - buf, [alat, blat].max + buf) &&
                                 plng.between?([alng, blng].min - buf, [alng, blng].max + buf)
  lat_scale = 69.0
  lng_scale = 69.0 * Math.cos(plat * Math::PI / 180.0)
  px = (plng - alng) * lng_scale; py = (plat - alat) * lat_scale
  dx = (blng - alng) * lng_scale; dy = (blat - alat) * lat_scale
  len_sq = dx * dx + dy * dy
  if len_sq < 1e-10
    return {
      distance_mi: Math.sqrt(px * px + py * py),
      lat: alat,
      lng: alng
    }
  end
  t = [[0.0, (px * dx + py * dy) / len_sq].max, 1.0].min
  {
    distance_mi: Math.sqrt((px - t * dx)**2 + (py - t * dy)**2),
    lat: alat + (blat - alat) * t,
    lng: alng + (blng - alng) * t
  }
end

def nearest_shoreline(lat, lng, segments, index = nil)
  return nil if segments.nil? || segments.empty?
  pool = index ? candidates(lat, lng, segments, index) : segments
  nearest = nil
  pool.each do |alat, alng, blat, blng|
    projection = point_to_segment_projection(lat, lng, alat, alng, blat, blng)
    next unless projection.is_a?(Hash)
    if nearest.nil? || projection[:distance_mi] < nearest[:distance_mi]
      nearest = projection
      return nearest if nearest[:distance_mi] < 0.01
    end
  end
  nearest
end

def in_service_area?(lat, lng)
  (lat.between?(FL_BOUNDS[:lat][0], FL_BOUNDS[:lat][1]) && lng.between?(FL_BOUNDS[:lng][0], FL_BOUNDS[:lng][1])) ||
  (lat.between?(TX_BOUNDS[:lat][0], TX_BOUNDS[:lat][1]) && lng.between?(TX_BOUNDS[:lng][0], TX_BOUNDS[:lng][1]))
end

# ---------------------------------------------------------------------------
# Core pipeline
# ---------------------------------------------------------------------------
def evaluate_coords(lat, lng, address_label)
  base = { address: address_label, lat: lat, lng: lng }
  return base.merge(result: 'OUT_OF_AREA', reason: 'Address is outside FL service area') unless in_service_area?(lat, lng)
  return base.merge(result: 'UNKNOWN', reason: 'Coastline data not loaded') if COASTLINE_SEGMENTS.nil?

  open_shore     = nearest_shoreline(lat, lng, COASTLINE_SEGMENTS,      COASTLINE_INDEX)
  interior_shore = nearest_shoreline(lat, lng, INTERIOR_WATER_SEGMENTS, INTERIOR_WATER_INDEX)
  dist_mi        = open_shore && open_shore[:distance_mi]
  finite         = dist_mi && dist_mi.finite? ? dist_mi : nil

  payload = base.merge(
    distance_mi: finite&.round(2),
    coastline_point: open_shore && { lat: open_shore[:lat].round(6), lng: open_shore[:lng].round(6) },
    interior_distance_mi: interior_shore && interior_shore[:distance_mi]&.round(2),
    interior_point: interior_shore && { lat: interior_shore[:lat].round(6), lng: interior_shore[:lng].round(6) }
  )

  if finite && finite <= COASTAL_RADIUS_MI
    payload.merge(result: 'YES',
      reason: "#{finite.round(2)} miles from coast",
      advisory_reason: interior_shore ? "#{interior_shore[:distance_mi].round(2)} miles from nearest interior bay / lagoon shoreline" : nil)
  else
    payload.merge(result: 'NO',
      reason: finite ? "#{finite.round(2)} miles from coast" : "More than 2 miles from coast",
      advisory_reason: interior_shore ? "#{interior_shore[:distance_mi].round(2)} miles from nearest interior bay / lagoon shoreline" : nil)
  end
end

def geocode(address)
  key = google_maps_server_key
  return nil if key.empty?

  resp = HTTParty.get('https://maps.googleapis.com/maps/api/geocode/json',
    query: { address: address, key: key }, timeout: 10)
  data = JSON.parse(resp.body)
  return nil unless data['status'] == 'OK'
  loc = data['results'][0]['geometry']['location']
  { lat: loc['lat'], lng: loc['lng'] }
rescue => e
  warn "[geocode] #{e.message}"; nil
end

def parse_coordinate(value)
  Float(value)
rescue ArgumentError, TypeError
  nil
end

def valid_coordinate_pair?(lat, lng)
  lat && lng && lat.between?(-90.0, 90.0) && lng.between?(-180.0, 180.0)
end

def check_address(address)
  coords = geocode(address)
  return { result: 'UNKNOWN', reason: 'Could not geocode address', address: address } unless coords
  evaluate_coords(coords[:lat], coords[:lng], address)
end

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
set :port, (ENV['PORT'] || 4567).to_i
set :bind, '0.0.0.0'

get '/'             do erb :index end
get '/api/check'    do content_type :json; address = params[:address].to_s.strip; halt 400, '{"error":"Address required"}' if address.empty?; check_address(address).to_json end
post '/check'       do content_type :json; address = params[:address].to_s.strip; halt 400, '{"error":"Address required"}' if address.empty?; check_address(address).to_json end
get '/api/check_coords' do
  content_type :json
  lat = parse_coordinate(params[:lat])
  lng = parse_coordinate(params[:lng])
  halt 400, { error: 'Valid lat and lng required' }.to_json unless valid_coordinate_pair?(lat, lng)
  evaluate_coords(lat, lng, "#{lat.round(5)}, #{lng.round(5)}").to_json
end
get '/coastline.geojson' do
  content_type 'application/geo+json'
  cache_control :public, max_age: 86400
  etag COASTLINE_VERSION
  send_file COASTLINE_FILE
end
get '/interior_water.geojson' do
  content_type 'application/geo+json'
  cache_control :public, max_age: 86400
  etag INTERIOR_WATER_VERSION
  send_file INTERIOR_WATER_FILE
end
get '/health' do
  content_type :json
  { ok: true, segments: COASTLINE_SEGMENTS&.size || 0, version: COASTLINE_VERSION }.to_json
end

# ---------------------------------------------------------------------------
# View
# ---------------------------------------------------------------------------
__END__

@@index
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>CoastFinder</title>
  <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"
    integrity="sha256-p4NxAoJBhIIN+hmNHrzRCf9tD/miZyoHS5obTRR9BMY=" crossorigin="">
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Helvetica Neue', sans-serif; background: #000; height: 100vh; overflow: hidden; }
    #map { position: fixed; inset: 0; width: 100%; height: 100%; }
    .leaflet-container { background: #dbe7ef; }
    .leaflet-control-attribution { font-size: 10px; }

    .search-panel {
      position: fixed; top: 20px; left: 50%; transform: translateX(-50%);
      z-index: 10; display: flex; align-items: center; gap: 10px;
      background: rgba(255,255,255,0.93); backdrop-filter: blur(20px) saturate(180%);
      -webkit-backdrop-filter: blur(20px) saturate(180%);
      border: 1px solid rgba(255,255,255,0.6); border-radius: 16px;
      padding: 10px 14px; box-shadow: 0 8px 32px rgba(0,0,0,0.18), 0 2px 8px rgba(0,0,0,0.1);
      width: min(620px, calc(100vw - 40px));
    }
    .search-icon { flex-shrink: 0; color: #8e8e93; width: 18px; height: 18px; }
    #address-input {
      flex: 1; border: none; background: transparent; font-size: 16px;
      color: #1c1c1e; outline: none; font-family: inherit;
    }
    #address-input::placeholder { color: #aeaeb2; }
    .search-btn {
      flex-shrink: 0; background: #007aff; color: white; border: none;
      border-radius: 10px; padding: 8px 18px; font-size: 14px; font-weight: 600;
      font-family: inherit; cursor: pointer; transition: background 0.15s, opacity 0.15s;
      white-space: nowrap;
    }
    .search-btn:hover { background: #0063d3; }
    .search-btn:disabled { opacity: 0.5; }
    .spinner { display: none; width: 16px; height: 16px; border: 2px solid rgba(0,122,255,0.25); border-top-color: #007aff; border-radius: 50%; animation: spin 0.7s linear infinite; flex-shrink: 0; }
    @keyframes spin { to { transform: rotate(360deg); } }

    .drop-panel {
      position: fixed; top: 96px; left: 24px; z-index: 10; width: min(228px, calc(100vw - 48px));
      background: rgba(255,255,255,0.9); backdrop-filter: blur(18px) saturate(180%);
      -webkit-backdrop-filter: blur(18px) saturate(180%);
      border: 1px solid rgba(255,255,255,0.65); border-radius: 16px; padding: 12px 14px;
      box-shadow: 0 8px 26px rgba(0,0,0,0.12);
    }
    .drop-title { font-size: 11px; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase; color: #8e8e93; margin-bottom: 6px; }
    .drop-copy { font-size: 11px; line-height: 1.35; color: #6b7280; margin-bottom: 10px; }
    .drop-btn {
      width: 100%; border: none; border-radius: 12px; padding: 10px 12px;
      background: #111827; color: #ffffff; font-size: 13px; font-weight: 700; cursor: pointer; font-family: inherit;
    }
    .drop-btn.active { background: #2563eb; }
    .drop-hint { margin-top: 8px; font-size: 11px; color: #6b7280; }

    .result-card {
      position: fixed; bottom: 28px; left: 24px; z-index: 10; width: min(350px, calc(100vw - 48px));
      background: rgba(255,255,255,0.94); backdrop-filter: blur(20px) saturate(180%);
      -webkit-backdrop-filter: blur(20px) saturate(180%);
      border: 1px solid rgba(255,255,255,0.6); border-radius: 20px; padding: 20px;
      box-shadow: 0 12px 40px rgba(0,0,0,0.20), 0 2px 8px rgba(0,0,0,0.08);
      display: none;
      transition: opacity 0.18s ease, transform 0.18s ease;
    }
    .result-card.visible { display: block; animation: cardIn 0.35s cubic-bezier(0.34,1.56,0.64,1); }
    .result-card.live { opacity: 0.78; transform: translateY(2px); }
    @keyframes cardIn { from { opacity:0; transform: translateY(16px) scale(0.96); } to { opacity:1; transform: translateY(0) scale(1); } }

    .result-badge {
      display: inline-flex; align-items: center; gap: 5px;
      font-size: 11px; font-weight: 700; letter-spacing: 0.06em;
      text-transform: uppercase; border-radius: 7px; padding: 4px 10px; margin-bottom: 12px;
    }
    .badge-coastal     { background: #fff3e0; color: #c45000; }
    .badge-not-coastal { background: #e8f5e9; color: #1b7a34; }
    .badge-out         { background: #f0f0f5; color: #6e6e80; }
    .badge-unknown     { background: #fff0f0; color: #c0392b; }

    .result-distance { font-size: 40px; font-weight: 700; letter-spacing: -0.03em; line-height: 1; color: #1c1c1e; display: flex; align-items: baseline; gap: 4px; margin-bottom: 4px; }
    .result-distance .unit { font-size: 16px; font-weight: 500; color: #8e8e93; }
    .result-subtitle { font-size: 11px; color: #8e8e93; text-transform: uppercase; letter-spacing: 0.08em; margin-bottom: 6px; }
    .result-label { font-size: 13px; color: #6e6e80; margin-bottom: 14px; line-height: 1.4; }
    .result-divider { border: none; border-top: 1px solid rgba(0,0,0,0.07); margin: 12px 0; }
    .result-address { font-size: 13px; color: #3a3a3c; font-weight: 500; line-height: 1.4; }
    .result-coords { font-size: 11px; color: #aeaeb2; margin-top: 4px; font-variant-numeric: tabular-nums; }

    .metric-list { display: grid; gap: 8px; margin-top: 12px; }
    .metric-row {
      display: flex; justify-content: space-between; align-items: center; gap: 10px;
      font-size: 12px; color: #3a3a3c;
    }
    .metric-label { display: flex; align-items: center; gap: 8px; color: #6e6e80; }
    .metric-value { font-weight: 700; color: #1c1c1e; font-variant-numeric: tabular-nums; }
    .dot { width: 10px; height: 10px; border-radius: 50%; flex-shrink: 0; }
    .dot-open { background: #f97316; }
    .dot-interior { background: #0ea5e9; }
    .hint { font-size: 11px; color: #8e8e93; margin-top: 10px; line-height: 1.35; }

    .action-row { display: flex; gap: 8px; margin-top: 12px; }
    .action-btn {
      border: none; border-radius: 10px; padding: 9px 12px; font-size: 12px; font-weight: 600;
      cursor: pointer; font-family: inherit;
    }
    .action-btn.primary { background: #e0f2fe; color: #075985; }
    .action-btn.secondary { background: #eef2ff; color: #1d4ed8; }
    .action-btn.ghost { background: #f3f4f6; color: #6b7280; }
    .action-btn.active { box-shadow: inset 0 0 0 2px rgba(37,99,235,0.22); }
    .action-btn:disabled { opacity: 0.45; cursor: default; }
    .action-stack { display: grid; gap: 10px; margin-top: 12px; }
    .chip-row { display: flex; gap: 6px; flex-wrap: wrap; }
    .chip {
      border: none; border-radius: 999px; padding: 7px 10px; font-size: 11px; font-weight: 700;
      letter-spacing: 0.02em; cursor: pointer; font-family: inherit; background: #f3f4f6; color: #4b5563;
    }
    .chip.active { background: #dbeafe; color: #1d4ed8; }
    .status-pill {
      display: inline-flex; align-items: center; gap: 6px; margin-top: 10px;
      border-radius: 999px; padding: 6px 10px; font-size: 11px; font-weight: 700;
      background: #eff6ff; color: #1d4ed8;
    }
    .status-pill.live {
      background: #fef3c7;
      color: #92400e;
    }

    .legend {
      position: fixed; bottom: 28px; right: 24px; z-index: 10; width: min(252px, calc(100vw - 48px));
      background: rgba(255,255,255,0.88); backdrop-filter: blur(16px);
      -webkit-backdrop-filter: blur(16px);
      border: 1px solid rgba(255,255,255,0.6); border-radius: 14px;
      padding: 12px 14px; box-shadow: 0 4px 20px rgba(0,0,0,0.1);
      font-size: 11px; color: #3a3a3c;
    }
    .legend-title { font-weight: 700; font-size: 11px; text-transform: uppercase; letter-spacing: 0.05em; color: #8e8e93; margin-bottom: 8px; }
    .legend-row { display: flex; align-items: center; gap: 8px; margin-top: 7px; }
    .legend-swatch-line { width: 24px; height: 3px; border-radius: 2px; flex-shrink: 0; background: #0ea5e9; opacity: 0.85; }
    .legend-swatch-line-dashed {
      width: 24px; height: 0; border-top: 3px dashed #38bdf8; opacity: 0.9; flex-shrink: 0;
    }
    .legend-swatch-measure { width: 24px; height: 0; border-top: 3px solid #f97316; flex-shrink: 0; }
    .layer-toggle { display: flex; align-items: center; gap: 8px; margin-top: 10px; color: #4b5563; }
    .layer-toggle input { accent-color: #0ea5e9; }

    .pin {
      border-radius: 50%;
      border: 3px solid #ffffff;
      box-shadow: 0 4px 14px rgba(0,0,0,0.24);
      cursor: grab;
    }
    .pin:active { cursor: grabbing; }
    .pin-property { width: 22px; height: 22px; background: #111827; }
    .pin-official { width: 16px; height: 16px; background: #f97316; }
    .pin-interior { width: 14px; height: 14px; background: #38bdf8; }

    .toast {
      position: fixed; top: 80px; left: 50%; transform: translateX(-50%);
      z-index: 20; background: rgba(44,44,46,0.95); color: #fff;
      padding: 10px 20px; border-radius: 12px; font-size: 14px; display: none;
    }

    @media (max-width: 720px) {
      .search-panel { width: calc(100vw - 24px); top: 12px; }
      .drop-panel { top: 74px; left: 12px; width: calc(100vw - 24px); }
      .result-card { left: 12px; bottom: 12px; width: calc(100vw - 24px); }
      .legend { right: 12px; bottom: auto; top: 188px; width: calc(100vw - 24px); }
      .action-row { flex-wrap: wrap; }
    }
  </style>
</head>
<body>

<div id="map"></div>

<div class="search-panel">
  <svg class="search-icon" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
    <circle cx="11" cy="11" r="8"/><path d="m21 21-4.35-4.35"/>
  </svg>
  <input id="address-input" type="text"
    placeholder="123 Ocean Dr, Miami Beach FL 33139"
    autocomplete="off" spellcheck="false">
  <div class="spinner" id="spinner"></div>
  <button class="search-btn" id="search-btn" onclick="runCheck()">Search</button>
</div>

<div class="drop-panel">
  <div class="drop-title">CoastFinder</div>
  <div class="drop-copy">Florida coastal proximity check. Search an address or drop a pin.</div>
  <button class="drop-btn" id="drop-pin-btn" type="button">Drop Property Pin</button>
  <div class="drop-hint" id="drop-pin-hint">Tip: double-click anywhere on the map to drop a pin instantly.</div>
</div>

<div class="result-card" id="result-card">
  <div id="result-badge" class="result-badge"></div>
  <div class="result-subtitle" id="result-subtitle">Open Ocean Coast</div>
  <div class="result-distance" id="result-distance">
    <span id="dist-value"></span>
    <span class="unit" id="dist-unit"></span>
  </div>
  <div id="result-label" class="result-label"></div>
  <hr class="result-divider">
  <div class="metric-list">
    <div class="metric-row">
      <div class="metric-label"><span class="dot dot-open"></span>Official open-coast line</div>
      <div class="metric-value" id="open-distance-detail">--</div>
    </div>
    <div class="metric-row">
      <div class="metric-label"><span class="dot dot-interior"></span>Nearest bay / lagoon line</div>
      <div class="metric-value" id="interior-distance-detail">--</div>
    </div>
  </div>
  <div class="status-pill" id="measure-status">Bay overlay on</div>
  <div class="action-stack">
    <div class="action-row">
      <button class="action-btn secondary" id="toggle-bay-overlay-btn" type="button">Bay Overlay On</button>
      <button class="action-btn ghost" id="recenter-btn" type="button" disabled>Recenter To Pin</button>
    </div>
  </div>
  <div class="hint" id="advisor-hint">Pinned property.</div>
  <hr class="result-divider">
  <div id="result-address" class="result-address"></div>
  <div id="result-coords" class="result-coords"></div>
</div>

<div class="legend">
  <div class="legend-title">Layers & Lines</div>
  <div class="legend-row"><div class="legend-swatch-line"></div>Open ocean coastline</div>
  <div class="legend-row"><div class="legend-swatch-line-dashed"></div>Interior bay / lagoon candidates</div>
  <div class="legend-row"><div class="legend-swatch-measure"></div>Official measured line</div>
  <label class="layer-toggle"><input id="toggle-interior-water" type="checkbox" checked> Show bay overlay</label>
</div>

<div class="toast" id="toast"></div>

<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"
  integrity="sha256-20nQCchB9co0qIjJZRGuk2/Z9VM+kNiyxNV1lvTlZBo=" crossorigin=""></script>
<script>
let map;
let activeMapProvider = null;
let googleBootTimedOut = false;
let currentResult = null;
let geojsonCache = {};
let layerVisibility = { open: true, interior: true };
let dropModeActive = false;
let dragPreviewTimer = null;
let coordRequestSeq = 0;
let googleState = { openLayer: null, interiorLayer: null, propertyMarker: null, officialMarker: null, officialLine: null, officialCircle: null };
let leafletState = { openLayer: null, interiorLayer: null, propertyMarker: null, officialMarker: null, officialLine: null, officialCircle: null };

function markerIcon(colorClass) {
  return L.divIcon({
    className: '',
    html: '<div class="pin ' + colorClass + '"></div>',
    iconSize: [22, 22],
    iconAnchor: [11, 11]
  });
}

function installSearchListener() {
  document.getElementById('address-input').addEventListener('keydown', function(e) {
    if (e.key === 'Enter') runCheck();
  });
  document.addEventListener('keydown', handleKeyboardShortcuts);
  document.getElementById('drop-pin-btn').addEventListener('click', toggleDropMode);
  document.getElementById('toggle-bay-overlay-btn').addEventListener('click', function() {
    layerVisibility.interior = !layerVisibility.interior;
    document.getElementById('toggle-interior-water').checked = layerVisibility.interior;
    syncLayerVisibility();
  });
  document.getElementById('recenter-btn').addEventListener('click', recenterToPropertyPin);
  document.getElementById('toggle-interior-water').addEventListener('change', function(e) {
    layerVisibility.interior = e.target.checked;
    syncLayerVisibility();
  });
}

function loadGoogleScript() {
  var script = document.createElement('script');
  script.src = 'https://maps.googleapis.com/maps/api/js?key=<%= google_maps_browser_key %>&callback=initGoogleMap';
  script.async = true;
  script.defer = true;
  script.onerror = function() {
    if (!activeMapProvider) {
      showToast('Google Maps failed to load, using fallback map');
      initLeafletMap();
    }
  };
  document.body.appendChild(script);

  setTimeout(function() {
    googleBootTimedOut = true;
    if (!activeMapProvider) {
      showToast('Google Maps did not initialize, using fallback map');
      initLeafletMap();
    }
  }, 4000);
}

function loadGeoJson(url, callback) {
  if (geojsonCache[url]) {
    callback(geojsonCache[url]);
    return;
  }
  fetch(url)
    .then(function(r) { return r.json(); })
    .then(function(data) {
      geojsonCache[url] = data;
      callback(data);
    })
    .catch(function() { showToast('Could not load map overlays'); });
}

function haversineMiles(a, b) {
  var toRad = Math.PI / 180;
  var dLat = (b.lat - a.lat) * toRad;
  var dLng = (b.lng - a.lng) * toRad;
  var lat1 = a.lat * toRad;
  var lat2 = b.lat * toRad;
  var s = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
          Math.sin(dLng / 2) * Math.sin(dLng / 2) * Math.cos(lat1) * Math.cos(lat2);
  return 3958.8 * 2 * Math.atan2(Math.sqrt(s), Math.sqrt(1 - s));
}

function projectPointToSegment(point, a, b) {
  var latScale = 69.0;
  var lngScale = 69.0 * Math.cos(point.lat * Math.PI / 180.0);
  var px = (point.lng - a.lng) * lngScale;
  var py = (point.lat - a.lat) * latScale;
  var dx = (b.lng - a.lng) * lngScale;
  var dy = (b.lat - a.lat) * latScale;
  var lenSq = dx * dx + dy * dy;
  if (lenSq < 1e-10) {
    return { lat: a.lat, lng: a.lng, distance: Math.sqrt(px * px + py * py) };
  }
  var t = Math.max(0, Math.min(1, (px * dx + py * dy) / lenSq));
  var projected = {
    lat: a.lat + (b.lat - a.lat) * t,
    lng: a.lng + (b.lng - a.lng) * t
  };
  return {
    lat: projected.lat,
    lng: projected.lng,
    distance: haversineMiles(point, projected)
  };
}

function getActiveReference(data) {
  if (!data) return null;

  if (data.coastline_point) {
    return {
      point: data.coastline_point,
      distance: data.distance_mi,
      subtitle: 'Open Ocean Coast',
      detail: data.reason,
      kind: 'open coast'
    };
  }

  if (data.interior_point) {
    return {
      point: data.interior_point,
      distance: data.interior_distance_mi,
      subtitle: 'Bay / Lagoon Reference',
      detail: 'Showing bay / lagoon reference distance. Official coastal flag still uses open coast.',
      kind: 'bay / lagoon'
    };
  }

  return null;
}

function updateReferenceUi(data) {
  if (!data) return;
  var reference = getActiveReference(data);
  var subtitleEl = document.getElementById('result-subtitle');
  var distValue = document.getElementById('dist-value');
  var distUnit = document.getElementById('dist-unit');
  var labelEl = document.getElementById('result-label');

  if (subtitleEl) {
    subtitleEl.textContent = reference ? reference.subtitle : 'Open Ocean Coast';
  }

  if (distValue && distUnit) {
    distValue.textContent = '';
    distUnit.textContent = '';
    if (reference && reference.distance != null && isFinite(reference.distance)) {
      distValue.textContent = Number(reference.distance).toFixed(2);
      distUnit.textContent = 'mi';
    } else if (data.result === 'NO') {
      distValue.textContent = '> 2';
      distUnit.textContent = 'mi';
    } else {
      distValue.textContent = '--';
    }
  }

  if (labelEl) {
    labelEl.textContent = reference ? reference.detail : data.reason;
  }
}

function updateOfficialReferenceGeometry() {
  if (!currentResult) return;
  var reference = getActiveReference(currentResult);
  if (!reference || !reference.point) return;

  if (activeMapProvider === 'google') {
    if (googleState.officialMarker) {
      googleState.officialMarker.setPosition(reference.point);
    }
    if (googleState.officialLine) {
      googleState.officialLine.setPath([{ lat: currentResult.lat, lng: currentResult.lng }, reference.point]);
    }
  } else if (activeMapProvider === 'leaflet') {
    if (leafletState.officialMarker) {
      leafletState.officialMarker.setLatLng([reference.point.lat, reference.point.lng]);
    }
    if (leafletState.officialLine) {
      leafletState.officialLine.setLatLngs([[currentResult.lat, currentResult.lng], [reference.point.lat, reference.point.lng]]);
    }
  }
}

function formatMiles(value, fallback) {
  if (value == null || !isFinite(value)) return fallback || '--';
  return value.toFixed(2) + ' mi';
}

function updateDropModeUi() {
  var btn = document.getElementById('drop-pin-btn');
  var hint = document.getElementById('drop-pin-hint');
  btn.classList.toggle('active', dropModeActive);
  btn.textContent = dropModeActive ? 'Click Map To Drop Pin' : 'Drop Property Pin';
  hint.textContent = dropModeActive
    ? 'Drop mode is on. Click once to place the property pin, or double-click any time for a quick drop.'
    : 'Tip: double-click anywhere on the map to drop a pin instantly.';

  if (activeMapProvider === 'google' && map) {
    map.setOptions({ draggableCursor: dropModeActive ? 'crosshair' : null });
  }

  var mapEl = document.getElementById('map');
  if (mapEl) {
    mapEl.style.cursor = dropModeActive ? 'crosshair' : '';
  }
}

function toggleDropMode() {
  dropModeActive = !dropModeActive;
  updateDropModeUi();
}

function exitDropMode() {
  dropModeActive = false;
  updateDropModeUi();
}

function updateMeasureModeUi() {
  document.getElementById('measure-status').textContent = layerVisibility.interior ? 'Bay overlay on' : 'Bay overlay off';
  var overlayBtn = document.getElementById('toggle-bay-overlay-btn');
  if (overlayBtn) {
    overlayBtn.textContent = layerVisibility.interior ? 'Bay Overlay On' : 'Bay Overlay Off';
    overlayBtn.classList.toggle('active', layerVisibility.interior);
  }
  if (currentResult) {
    document.getElementById('advisor-hint').textContent = currentResult.advisory_reason || 'Pinned property.';
  }
}

function placePropertyPin(lat, lng) {
  exitDropMode();
  checkCoords(lat, lng);
}

function makeGoogleCircleMarker(color, scale) {
  return {
    path: google.maps.SymbolPath.CIRCLE,
    scale: scale,
    fillColor: color,
    fillOpacity: 1,
    strokeColor: '#ffffff',
    strokeWeight: 2
  };
}

// Property pin: small visible dot (r=8) inside a large transparent SVG hit area (40px)
// so the grab target is easy to hit without making the dot look bigger.
function makeGooglePropertyMarkerIcon() {
  var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="44" height="44" viewBox="0 0 44 44">' +
    '<circle cx="22" cy="22" r="22" fill="transparent"/>' +
    '<circle cx="22" cy="22" r="8" fill="#111827" stroke="#ffffff" stroke-width="2.5"/>' +
    '</svg>';
  return {
    url: 'data:image/svg+xml;charset=UTF-8,' + encodeURIComponent(svg),
    size: new google.maps.Size(44, 44),
    origin: new google.maps.Point(0, 0),
    anchor: new google.maps.Point(22, 22)
  };
}

function syncLayerVisibility() {
  if (activeMapProvider === 'google') {
    if (googleState.openLayer) {
      googleState.openLayer.setStyle({ strokeColor: '#0ea5e9', strokeWeight: 2.5, strokeOpacity: 0.82, clickable: false });
      googleState.openLayer.setMap(layerVisibility.open ? map : null);
    }
    if (googleState.interiorLayer) {
      googleState.interiorLayer.setStyle({ strokeColor: '#38bdf8', strokeWeight: 2, strokeOpacity: 0.72, clickable: false });
      googleState.interiorLayer.setMap(layerVisibility.interior ? map : null);
    }
  } else if (activeMapProvider === 'leaflet') {
    if (leafletState.openLayer) {
      if (layerVisibility.open && !map.hasLayer(leafletState.openLayer)) map.addLayer(leafletState.openLayer);
      if (!layerVisibility.open && map.hasLayer(leafletState.openLayer)) map.removeLayer(leafletState.openLayer);
    }
    if (leafletState.interiorLayer) {
      if (layerVisibility.interior && !map.hasLayer(leafletState.interiorLayer)) map.addLayer(leafletState.interiorLayer);
      if (!layerVisibility.interior && map.hasLayer(leafletState.interiorLayer)) map.removeLayer(leafletState.interiorLayer);
    }
  }

  updateReferenceUi(currentResult);
  updateOfficialReferenceGeometry();
}

function updatePropertyPreview(lat, lng) {
  var reference = currentResult ? getActiveReference(currentResult) : null;
  var posGoogle = { lat: lat, lng: lng };
  var posLeaflet = [lat, lng];
  if (activeMapProvider === 'google') {
    if (googleState.officialCircle) googleState.officialCircle.setCenter(posGoogle);
    if (googleState.officialLine && reference && reference.point) {
      googleState.officialLine.setPath([posGoogle, reference.point]);
    }
  } else if (activeMapProvider === 'leaflet') {
    if (leafletState.officialCircle) leafletState.officialCircle.setLatLng(posLeaflet);
    if (leafletState.officialLine && reference && reference.point) {
      leafletState.officialLine.setLatLngs([posLeaflet, [reference.point.lat, reference.point.lng]]);
    }
  }
}

function initGoogleLayers() {
  googleState.openLayer = new google.maps.Data();
  googleState.interiorLayer = new google.maps.Data();
  googleState.openLayer.setMap(map);
  googleState.interiorLayer.setMap(map);

  loadGeoJson('/coastline.geojson', function(data) {
    googleState.openLayer.addGeoJson(data);
    syncLayerVisibility();
  });
  loadGeoJson('/interior_water.geojson', function(data) {
    googleState.interiorLayer.addGeoJson(data);
    syncLayerVisibility();
  });
}

function initLeafletLayers() {
  loadGeoJson('/coastline.geojson', function(data) {
    leafletState.openLayer = L.geoJSON(data, {
      style: function() { return { color: '#0ea5e9', weight: 2.5, opacity: 0.82, interactive: false }; }
    });
    syncLayerVisibility();
  });
  loadGeoJson('/interior_water.geojson', function(data) {
    leafletState.interiorLayer = L.geoJSON(data, {
      style: function() { return { color: '#38bdf8', weight: 2, opacity: 0.72, dashArray: '6 6', interactive: false }; }
    });
    syncLayerVisibility();
  });
}

function clearOfficialGraphics() {
  if (activeMapProvider === 'google') {
    if (googleState.officialMarker) googleState.officialMarker.setMap(null);
    if (googleState.officialLine) googleState.officialLine.setMap(null);
    if (googleState.officialCircle) googleState.officialCircle.setMap(null);
    googleState.officialMarker = null;
    googleState.officialLine = null;
    googleState.officialCircle = null;
  } else if (activeMapProvider === 'leaflet') {
    if (leafletState.officialMarker) map.removeLayer(leafletState.officialMarker);
    if (leafletState.officialLine) map.removeLayer(leafletState.officialLine);
    if (leafletState.officialCircle) map.removeLayer(leafletState.officialCircle);
    leafletState.officialMarker = null;
    leafletState.officialLine = null;
    leafletState.officialCircle = null;
  }
}

function recenterToPropertyPin() {
  if (!currentResult || !map) return;
  var target = activeMapProvider === 'google'
    ? { lat: currentResult.lat, lng: currentResult.lng }
    : [currentResult.lat, currentResult.lng];
  if (activeMapProvider === 'google') map.panTo(target);
  if (activeMapProvider === 'leaflet') map.panTo(target, { animate: true });
}

function handleKeyboardShortcuts(e) {
  if (e.key !== 'Escape') return;
  if (dropModeActive) exitDropMode();
}

function setLiveDragState(on) {
  var card = document.getElementById('result-card');
  var status = document.getElementById('measure-status');
  if (card && card.classList.contains('visible')) {
    card.classList.toggle('live', on);
  }
  if (status) {
    status.classList.toggle('live', on);
    if (on) {
      status.dataset.savedLabel = status.textContent;
      status.textContent = 'Live updating';
    } else if (status.dataset.savedLabel) {
      status.textContent = status.dataset.savedLabel;
      delete status.dataset.savedLabel;
    }
  }
}

function updateResultBadge(data) {
  var badgeEl = document.getElementById('result-badge');
  badgeEl.className = 'result-badge ' + {
    YES: 'badge-coastal', NO: 'badge-not-coastal',
    OUT_OF_AREA: 'badge-out', UNKNOWN: 'badge-unknown'
  }[data.result];
  badgeEl.textContent = {
    YES: 'Yes — Flagged for Review', NO: 'No — Not Coastal',
    OUT_OF_AREA: 'Out of Area', UNKNOWN: 'Unknown'
  }[data.result];
}

function updateDistanceMetrics(data) {
  document.getElementById('open-distance-detail').textContent = formatMiles(data.distance_mi, data.result === 'NO' ? '> 2 mi' : '--');
  document.getElementById('interior-distance-detail').textContent = formatMiles(data.interior_distance_mi, 'None');
}

function updateOfficialGeometryForCurrentResult() {
  if (!currentResult) return;
  var ringColor = currentResult.result === 'YES' ? '#f97316' : (currentResult.result === 'NO' ? '#22c55e' : '#8e8e93');
  var reference = getActiveReference(currentResult);

  if (activeMapProvider === 'google') {
    var propertyPos = { lat: currentResult.lat, lng: currentResult.lng };
    if (googleState.officialCircle) {
      googleState.officialCircle.setCenter(propertyPos);
      googleState.officialCircle.setOptions({
        strokeColor: ringColor,
        fillColor: ringColor
      });
    }
    if (reference && reference.point) {
      if (googleState.officialMarker) googleState.officialMarker.setPosition(reference.point);
      if (googleState.officialLine) googleState.officialLine.setPath([propertyPos, reference.point]);
    }
  } else if (activeMapProvider === 'leaflet') {
    var propertyLatLng = [currentResult.lat, currentResult.lng];
    if (leafletState.officialCircle) {
      leafletState.officialCircle.setLatLng(propertyLatLng);
      leafletState.officialCircle.setStyle({ color: ringColor, fillColor: ringColor });
    }
    if (reference && reference.point) {
      var officialLatLng = [reference.point.lat, reference.point.lng];
      if (leafletState.officialMarker) leafletState.officialMarker.setLatLng(officialLatLng);
      if (leafletState.officialLine) leafletState.officialLine.setLatLngs([propertyLatLng, officialLatLng]);
    }
  }
}

function applyLivePreviewResult(data) {
  currentResult = data;
  updateResultBadge(data);
  updateDistanceMetrics(data);
  document.getElementById('result-address').textContent = data.address;
  document.getElementById('result-coords').textContent = data.lat.toFixed(5) + ', ' + data.lng.toFixed(5);
  document.getElementById('advisor-hint').textContent = 'Dragging pin. Distances update live as you move.';
  updateReferenceUi(data);
  updateOfficialGeometryForCurrentResult();
}

function requestCoordCheck(lat, lng, options) {
  var opts = options || {};
  var requestId = ++coordRequestSeq;
  fetch('/api/check_coords?lat=' + lat + '&lng=' + lng)
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (requestId !== coordRequestSeq) return;
      if (opts.preview) {
        applyLivePreviewResult(data);
      } else {
        showResult(data, !!opts.animate);
      }
    })
    .catch(function() {});
}

function scheduleDragPreview(lat, lng) {
  if (dragPreviewTimer) clearTimeout(dragPreviewTimer);
  setLiveDragState(true);
  dragPreviewTimer = setTimeout(function() {
    requestCoordCheck(lat, lng, { animate: false, preview: true });
  }, 70);
}

function drawResultGeometry(data, animate) {
  clearOfficialGraphics();
  var ringColor = data.result === 'YES' ? '#f97316' : (data.result === 'NO' ? '#22c55e' : '#8e8e93');
  var reference = getActiveReference(data);

  if (activeMapProvider === 'google') {
    var propertyPos = { lat: data.lat, lng: data.lng };
    if (!googleState.propertyMarker) {
      googleState.propertyMarker = new google.maps.Marker({
        position: propertyPos,
        map: map,
        draggable: true,
        icon: makeGooglePropertyMarkerIcon()
      });
      googleState.propertyMarker.addListener('dragend', function(e) {
        if (dragPreviewTimer) clearTimeout(dragPreviewTimer);
        setLiveDragState(false);
        placePropertyPin(e.latLng.lat(), e.latLng.lng());
      });
      googleState.propertyMarker.addListener('drag', function(e) {
        updatePropertyPreview(e.latLng.lat(), e.latLng.lng());
        scheduleDragPreview(e.latLng.lat(), e.latLng.lng());
      });
    } else {
      googleState.propertyMarker.setPosition(propertyPos);
    }

    googleState.officialCircle = new google.maps.Circle({
      map: map,
      center: propertyPos,
      radius: 3218.69,
      strokeColor: ringColor,
      strokeOpacity: 0.55,
      strokeWeight: 1.5,
      fillColor: ringColor,
      fillOpacity: 0.07,
      clickable: false
    });

    if (reference && reference.point) {
      var officialPoint = reference.point;
      googleState.officialMarker = new google.maps.Marker({
        position: officialPoint,
        map: map,
        icon: makeGoogleCircleMarker('#f97316', 6)
      });
      googleState.officialLine = new google.maps.Polyline({
        map: map,
        path: [propertyPos, officialPoint],
        strokeColor: '#f97316',
        strokeOpacity: 0.95,
        strokeWeight: 3
      });
    }

    if (animate) { map.panTo(propertyPos); map.setZoom(12); }
    else { map.panTo(propertyPos); }
  } else if (activeMapProvider === 'leaflet') {
    var propertyLatLng = [data.lat, data.lng];
    if (!leafletState.propertyMarker) {
      leafletState.propertyMarker = L.marker(propertyLatLng, { icon: markerIcon('pin-property'), draggable: true }).addTo(map);
      leafletState.propertyMarker.on('dragend', function(e) {
        var latLng = e.target.getLatLng();
        if (dragPreviewTimer) clearTimeout(dragPreviewTimer);
        setLiveDragState(false);
        placePropertyPin(latLng.lat, latLng.lng);
      });
      leafletState.propertyMarker.on('drag', function(e) {
        var latLng = e.target.getLatLng();
        updatePropertyPreview(latLng.lat, latLng.lng);
        scheduleDragPreview(latLng.lat, latLng.lng);
      });
    } else {
      leafletState.propertyMarker.setLatLng(propertyLatLng);
    }

    leafletState.officialCircle = L.circle(propertyLatLng, {
      radius: 3218.69,
      color: ringColor,
      opacity: 0.55,
      weight: 1.5,
      fillColor: ringColor,
      fillOpacity: 0.07
    }).addTo(map);

    if (reference && reference.point) {
      var officialLatLng = [reference.point.lat, reference.point.lng];
      leafletState.officialMarker = L.marker(officialLatLng, {
        icon: markerIcon('pin-official')
      }).addTo(map);
      leafletState.officialLine = L.polyline([propertyLatLng, officialLatLng], {
        color: '#f97316',
        weight: 3,
        opacity: 0.95
      }).addTo(map);
    }

    if (animate) { map.setView(propertyLatLng, 12, { animate: true }); }
    else { map.panTo(propertyLatLng, { animate: true }); }
  }
}

function initGoogleMap() {
  if (activeMapProvider) return;
  activeMapProvider = 'google';
  map = new google.maps.Map(document.getElementById('map'), {
    center: { lat: 27.8, lng: -83.5 }, zoom: 7,
    mapTypeId: 'roadmap',
    disableDefaultUI: true,
    disableDoubleClickZoom: true,
    zoomControl: true,
    zoomControlOptions: { position: google.maps.ControlPosition.RIGHT_CENTER },
    styles: [
      { featureType: 'water',     elementType: 'geometry',    stylers: [{ color: '#b8d9ea' }] },
      { featureType: 'landscape', elementType: 'geometry',    stylers: [{ color: '#f5f5f0' }] },
      { featureType: 'road',      elementType: 'geometry',    stylers: [{ color: '#ffffff' }] },
      { featureType: 'road.arterial', elementType: 'geometry', stylers: [{ color: '#ececec' }] },
      { featureType: 'poi',       stylers: [{ visibility: 'off' }] },
      { featureType: 'transit',   stylers: [{ visibility: 'off' }] },
      { featureType: 'administrative', elementType: 'labels.text.fill', stylers: [{ color: '#555' }] }
    ]
  });
  initGoogleLayers();
  map.addListener('click', function(e) {
    if (dropModeActive) {
      placePropertyPin(e.latLng.lat(), e.latLng.lng());
      return;
    }
  });
  map.addListener('dblclick', function(e) {
    placePropertyPin(e.latLng.lat(), e.latLng.lng());
  });

  if (googleBootTimedOut) {
    showToast('Google Maps initialized after delay');
  }
  updateDropModeUi();
  updateMeasureModeUi();
}

function initLeafletMap() {
  if (activeMapProvider) return;
  activeMapProvider = 'leaflet';
  map = L.map('map', { zoomControl: false, doubleClickZoom: false }).setView([27.8, -83.5], 7);
  L.control.zoom({ position: 'right' }).addTo(map);

  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19,
    attribution: '&copy; OpenStreetMap contributors'
  }).addTo(map);
  initLeafletLayers();
  map.on('click', function(e) {
    if (dropModeActive) {
      placePropertyPin(e.latlng.lat, e.latlng.lng);
      return;
    }
  });
  map.on('dblclick', function(e) {
    placePropertyPin(e.latlng.lat, e.latlng.lng);
  });
  updateDropModeUi();
  updateMeasureModeUi();
}

function runCheck() {
  const address = document.getElementById('address-input').value.trim();
  if (!address) return;
  setLoading(true);
  fetch('/api/check?address=' + encodeURIComponent(address))
    .then(function(r) { return r.json(); })
    .then(function(data) { setLoading(false); showResult(data, true); })
    .catch(function() { setLoading(false); showToast('Request failed — try again'); });
}

function checkCoords(lat, lng) {
  requestCoordCheck(lat, lng, { animate: false });
}

function showResult(data, animate) {
  currentResult = data;
  setLiveDragState(false);

  // 1. Update result card content first — always, regardless of map state.
  //    This decouples the UI result from any map-drawing errors.
  updateResultBadge(data);
  updateDistanceMetrics(data);
  document.getElementById('result-address').textContent = data.address || '';
  var coordsEl = document.getElementById('result-coords');
  coordsEl.textContent = (data.lat != null && data.lng != null)
    ? data.lat.toFixed(5) + ', ' + data.lng.toFixed(5)
    : '';
  document.getElementById('advisor-hint').textContent = data.advisory_reason || 'Pinned property.';
  document.getElementById('recenter-btn').disabled = (data.lat == null);

  // 2. Make the card visible.
  var card = document.getElementById('result-card');
  card.className = 'result-card';
  void card.offsetWidth; // reflow for re-animation
  card.className = 'result-card visible';
  updateReferenceUi(data);

  // 3. Draw map geometry — best-effort; errors do not affect the card display.
  if (data.lat != null && data.lng != null) {
    try { drawResultGeometry(data, animate); } catch (e) { console.warn('[coastal-check] map draw error:', e); }
  }
}

function setLoading(on) {
  document.getElementById('spinner').style.display = on ? 'block' : 'none';
  var btn = document.getElementById('search-btn');
  btn.textContent = on ? 'Searching...' : 'Search';
  btn.disabled    = on;
}

function showToast(msg) {
  var t = document.getElementById('toast');
  t.textContent = msg;
  t.style.display = 'block';
  setTimeout(function() { t.style.display = 'none'; }, 3000);
}

window.gm_authFailure = function() {
  if (!activeMapProvider) {
    showToast('Google Maps key blocked in browser, using fallback map');
    initLeafletMap();
  }
};

document.addEventListener('DOMContentLoaded', function() {
  installSearchListener();
  loadGoogleScript();
});
</script>
</body>
</html>

