#!/usr/bin/env ruby
# encoding: utf-8
# ---------------------------------------------------------------------------
# setup_coastline.rb
#
# Downloads the US Census Bureau TIGER/Line National Coastline (L4150),
# filters to Florida (Atlantic + Gulf) and Texas (Gulf) outer ocean coast only,
# excludes inner bay/estuary/lagoon shorelines via defined exclusion zones,
# and saves the result as data/coastline.geojson.
#
# Data source:
#   US Census Bureau TIGER/Line 2023 - National Coastline
#   https://www2.census.gov/geo/tiger/TIGER2023/COASTLINE/
#   MTFCC L4150: "Coastline" (national boundary along navigable waters)
#   Named features: "Atlantic", "Gulf" (others: Pacific, Great Lakes, etc.)
#
# Run once before starting the app:
#   bundle exec ruby bin/setup_coastline.rb
#
# No external GIS tools required — pure Ruby shapefile parser included.
# ---------------------------------------------------------------------------

require 'net/http'
require 'tempfile'
require 'json'
require 'fileutils'
require 'uri'
require 'tmpdir'
begin; require 'zip'; rescue LoadError; end  # optional

CENSUS_URL           = 'https://www2.census.gov/geo/tiger/TIGER2023/COASTLINE/tl_2023_us_coastline.zip'
OUTPUT_FILE          = File.join(__dir__, '..', 'data', 'coastline.geojson')
INTERIOR_OUTPUT_FILE = File.join(__dir__, '..', 'data', 'interior_water.geojson')

# ---------------------------------------------------------------------------
# FL + TX bounding box (outer ocean coast coverage area)
# ---------------------------------------------------------------------------
MIN_LNG = -97.6; MAX_LNG = -79.7
MIN_LAT =  24.2; MAX_LAT =  31.2

# ---------------------------------------------------------------------------
# Bay exclusion zones — coastline segments whose midpoint falls inside any of
# these boxes are excluded. They represent inner bay/estuary/lagoon shorelines
# where Census L4150 incorrectly traces enclosed water body boundaries.
#
# Coordinates chosen to cover bay interiors while leaving the bay MOUTH and
# the adjacent ocean coast OUTSIDE the exclusion zone, so Gulf/Atlantic-facing
# properties near bay entrances are still correctly flagged.
# ---------------------------------------------------------------------------
BAY_EXCLUSIONS = [
  # ── FLORIDA ──────────────────────────────────────────────────────────────
  # Tampa Bay and Charlotte Harbor were intentionally removed from exclusions.
  # The current underwriting interpretation treats them as open water.

  # Indian River Lagoon — split into two latitude bands with tighter eastern boundaries.
  # The barrier islands here are narrow (1-3 mi wide); the lagoon lies just west of the
  # Atlantic coast. Eastern boundaries are set just west of the ocean shoreline longitude
  # so Atlantic-facing beach segments are NOT excluded.
  #   central band (Cocoa Beach area): Atlantic coast ~-80.61°W, IRL at ~-80.64°W+
  #   south band (Vero Beach area):    Atlantic coast ~-80.38°W, IRL at ~-80.42°W+
  { name: 'Indian River Lagoon (central)', lat: [27.75, 28.50], lng: [-80.75, -80.62] },
  { name: 'Indian River Lagoon (south)',   lat: [26.92, 27.75], lng: [-80.58, -80.40] },

  # Mosquito Lagoon — eastern boundary tightened from -80.75 to -80.93 so that the
  # Atlantic coast at New Smyrna Beach (~-80.921°W) falls outside the exclusion zone.
  { name: 'Mosquito Lagoon',              lat: [28.75, 29.10], lng: [-81.02, -80.93] },

  # Biscayne Bay (Miami area inner bay)
  # Eastern boundary -80.22 keeps Miami Beach's Atlantic coast (~-80.13°W) outside.
  { name: 'Biscayne Bay',                 lat: [25.35, 25.88], lng: [-80.50, -80.22] },

  # Florida Bay (south of Everglades, enclosed by FL Keys)
  # Minimum lat raised from 24.68 to 24.75 so that Marathon Key (~24.706°N) and the
  # Middle Keys' ocean-facing Atlantic coast fall outside the exclusion zone.
  { name: 'Florida Bay',                  lat: [24.75, 25.40], lng: [-81.40, -80.40] },

  # Apalachicola / St. George Sound — southern boundary raised from 29.60 to 29.68
  # so that St. George Island's Gulf beach (~29.647°N) is outside the exclusion zone.
  { name: 'Apalachicola Bay',             lat: [29.68, 29.90], lng: [-85.22, -84.50] },

  # Apalachee Bay inner (Suwannee River delta, St. Marks)
  { name: 'Apalachee Bay inner',          lat: [29.75, 30.05], lng: [-84.50, -83.70] },

  # Choctawhatchee Bay — southern boundary raised from 30.32 to 30.40 so that
  # Destin (~30.388°N) and Fort Walton Beach (~30.381°N) Gulf beaches are outside.
  { name: 'Choctawhatchee Bay',           lat: [30.40, 30.60], lng: [-86.80, -85.92] },

  # Pensacola Bay / Escambia Bay / Santa Rosa Sound — southern boundary raised from
  # 30.25 to 30.42 so that Pensacola Beach (~30.331°N) and Navarre Beach (~30.392°N)
  # Gulf-facing coast on Santa Rosa Island are outside the exclusion zone.
  { name: 'Pensacola Bay',                lat: [30.42, 30.55], lng: [-87.45, -86.82] },

  # St. Andrews Bay (Panama City area)
  { name: 'St. Andrews Bay',              lat: [30.10, 30.30], lng: [-85.80, -85.55] },

  # ── TEXAS ────────────────────────────────────────────────────────────────
  # Galveston Bay / Trinity Bay / East Bay / West Bay — southern boundary raised from
  # 29.35 to 29.52 so that Crystal Beach / Bolivar Peninsula Gulf coast (~29.476°N)
  # is outside this zone. Galveston Island beach (~29.24°N) remains outside.
  { name: 'Galveston Bay',                lat: [29.52, 29.90], lng: [-95.22, -94.38] },

  # Matagorda Bay / Lavaca Bay — southern lat min raised (28.42 → 28.65) and eastern
  # lng boundary adjusted (-95.52 → -95.75) so Sargent Beach (~28.773, -95.651) is outside.
  { name: 'Matagorda Bay',                lat: [28.65, 28.95], lng: [-96.72, -95.75] },

  # San Antonio Bay (Guadalupe River delta area)
  { name: 'San Antonio Bay',              lat: [28.30, 28.70], lng: [-97.00, -96.52] },

  # Aransas Bay / Copano Bay / Redfish Bay / St. Charles Bay
  { name: 'Aransas Bay',                  lat: [27.95, 28.30], lng: [-97.25, -96.85] },

  # Corpus Christi Bay / Nueces Bay / Oso Bay — eastern lng boundary tightened from
  # -97.08 to -97.25 so that Corpus Christi Beach (~-97.220°W) is outside the exclusion.
  { name: 'Corpus Christi Bay',           lat: [27.70, 28.05], lng: [-97.55, -97.25] },

  # Laguna Madre — long narrow lagoon between Padre Island and TX mainland.
  # Padre Island Gulf coast is at ~-97.13 to -97.15°W; exclusion starts at -97.17°W.
  { name: 'Laguna Madre',                 lat: [25.82, 27.52], lng: [-97.62, -97.17] },

  # Baffin Bay (southern TX, enclosed bay off Laguna Madre)
  { name: 'Baffin Bay',                   lat: [26.95, 27.35], lng: [-97.70, -97.48] },
].freeze

# Long straight man-made crossings that appear in the Census coastline linework.
# These should not act as shoreline measurement targets.
SEGMENT_EXCLUSIONS = [
  {
    name: 'Old Tampa Bay causeway crossing',
    lat: [27.94, 27.99],
    lng: [-82.66, -82.60],
    min_length_mi: 0.9
  }
].freeze

def in_bay_exclusion?(mid_lat, mid_lng)
  BAY_EXCLUSIONS.any? do |zone|
    mid_lat.between?(zone[:lat][0], zone[:lat][1]) &&
    mid_lng.between?(zone[:lng][0], zone[:lng][1])
  end
end

def excluded_crossing_segment?(alat, alng, blat, blng)
  mid_lat = (alat + blat) / 2.0
  mid_lng = (alng + blng) / 2.0
  length_mi = Math.sqrt((((blng - alng) * 60.0))**2 + (((blat - alat) * 69.0))**2)

  SEGMENT_EXCLUSIONS.any? do |zone|
    mid_lat.between?(zone[:lat][0], zone[:lat][1]) &&
      mid_lng.between?(zone[:lng][0], zone[:lng][1]) &&
      length_mi >= zone[:min_length_mi]
  end
end

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------
puts "Coastal Proximity Check — Coastline Setup"
puts "Source: US Census Bureau TIGER/Line 2023 (L4150 National Coastline)"
puts "URL:    #{CENSUS_URL}"
puts

zip_path = File.join(Dir.tmpdir, 'tl_2023_us_coastline.zip')
shp_path = zip_path.sub('.zip', '.shp')
dbf_path = zip_path.sub('.zip', '.dbf')

unless File.exist?(shp_path)
  print "Downloading coastline shapefile (#{CENSUS_URL})... "
  uri  = URI(CENSUS_URL)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 30
  http.read_timeout = 120

  http.start do |h|
    req  = Net::HTTP::Get.new(uri)
    h.request(req) do |resp|
      raise "HTTP #{resp.code}" unless resp.code == '200'
      File.open(zip_path, 'wb') { |f| resp.read_body { |chunk| f.write(chunk) } }
    end
  end
  puts "done (#{(File.size(zip_path)/1048576.0).round(1)} MB)"

  print "Extracting... "
  system("cd #{Dir.tmpdir} && unzip -q -o #{zip_path} tl_2023_us_coastline.shp tl_2023_us_coastline.dbf tl_2023_us_coastline.shx")
  puts "done"
else
  puts "Using cached shapefile at #{shp_path}"
end

# ---------------------------------------------------------------------------
# Parse DBF (attribute table)
# ---------------------------------------------------------------------------
dbf          = File.binread(dbf_path)
num_records  = dbf[4, 4].unpack('l<')[0]
header_size  = dbf[8, 2].unpack('s<')[0]
record_size  = dbf[10, 2].unpack('s<')[0]
dbf_names    = (0...num_records).map { |i| dbf[header_size + i * record_size + 1, 100].strip }

# ---------------------------------------------------------------------------
# Parse SHP (geometry) — ESRI Shapefile type 3 (Polyline)
# ---------------------------------------------------------------------------
shp     = File.binread(shp_path)
pos     = 100  # skip 100-byte file header
features          = []
interior_features = []
rec_idx  = 0

while pos < shp.size
  content_len = shp[pos + 4, 4].unpack('N')[0] * 2
  pos += 8
  shape_type = shp[pos, 4].unpack('V')[0]

  if shape_type == 3
    name = dbf_names[rec_idx] || ''

    if name == 'Atlantic' || name == 'Gulf'
      # Bounding box of this record
      bbox_minx, bbox_miny, bbox_maxx, bbox_maxy = shp[pos + 4, 32].unpack('EEEE')

      # Only process records that overlap the FL/TX area of interest
      if bbox_maxx >= MIN_LNG && bbox_minx <= MAX_LNG &&
         bbox_maxy >= MIN_LAT  && bbox_miny <= MAX_LAT

        num_parts  = shp[pos + 36, 4].unpack('V')[0]
        num_points = shp[pos + 40, 4].unpack('V')[0]
        parts      = shp[pos + 44, num_parts * 4].unpack('V*')
        pts_offset = pos + 44 + num_parts * 4

        all_points = (0...num_points).map { |pi|
          shp[pts_offset + pi * 16, 16].unpack('EE')  # [lng, lat]
        }

        (0...num_parts).each do |pi|
          s   = parts[pi]
          e   = (pi + 1 < num_parts ? parts[pi + 1] : num_points) - 1
          pts = all_points[s..e]

          # Only keep segments that have points inside our bounding box
          in_area = pts.any? { |x, y|
            x.between?(MIN_LNG, MAX_LNG) && y.between?(MIN_LAT, MAX_LAT)
          }
          next unless in_area && pts.size >= 2

          # Filter out bay/estuary shoreline segments.
          # Use the segment midpoint to check against bay exclusion zones.
          # Iterate over individual vertex-to-vertex segments and drop bay ones.
          ocean_pts    = []
          interior_pts = []

          pts.each_cons(2) do |(alng, alat), (blng, blat)|
            mid_lat = (alat + blat) / 2.0
            mid_lng = (alng + blng) / 2.0
            if excluded_crossing_segment?(alat, alng, blat, blng)
              if ocean_pts.size >= 2
                features << {
                  'type'       => 'Feature',
                  'properties' => { 'name' => name },
                  'geometry'   => { 'type' => 'LineString', 'coordinates' => ocean_pts.dup }
                }
              end
              ocean_pts = []

              if interior_pts.size >= 2
                interior_features << {
                  'type'       => 'Feature',
                  'properties' => { 'name' => name },
                  'geometry'   => { 'type' => 'LineString', 'coordinates' => interior_pts.dup }
                }
              end
              interior_pts = []
            elsif in_bay_exclusion?(mid_lat, mid_lng)
              if ocean_pts.size >= 2
                features << {
                  'type'       => 'Feature',
                  'properties' => { 'name' => name },
                  'geometry'   => { 'type' => 'LineString', 'coordinates' => ocean_pts.dup }
                }
              end
              ocean_pts = []

              interior_pts << [alng, alat] if interior_pts.empty?
              interior_pts << [blng, blat]
            else
              if interior_pts.size >= 2
                interior_features << {
                  'type'       => 'Feature',
                  'properties' => { 'name' => name },
                  'geometry'   => { 'type' => 'LineString', 'coordinates' => interior_pts.dup }
                }
              end
              interior_pts = []

              ocean_pts << [alng, alat] if ocean_pts.empty?
              ocean_pts << [blng, blat]
            end
          end

          if ocean_pts.size >= 2
            features << {
              'type'       => 'Feature',
              'properties' => { 'name' => name },
              'geometry'   => { 'type' => 'LineString', 'coordinates' => ocean_pts }
            }
          end

          if interior_pts.size >= 2
            interior_features << {
              'type'       => 'Feature',
              'properties' => { 'name' => name },
              'geometry'   => { 'type' => 'LineString', 'coordinates' => interior_pts }
            }
          end
        end
      end
    end
  end

  pos += content_len
  rec_idx += 1
end

puts "Segments extracted:  #{features.size}"
puts "Interior segments split: #{interior_features.size}"
puts "Bay segments classified via #{BAY_EXCLUSIONS.size} exclusion zones"
puts "Bridge / crossing segments removed via #{SEGMENT_EXCLUSIONS.size} segment exclusions"
puts

# ---------------------------------------------------------------------------
# Spot-check validation
# ---------------------------------------------------------------------------
def min_dist_miles(lat, lng, segs)
  segs.map do |f|
    f['geometry']['coordinates'].each_cons(2).map do |(alng,alat),(blng,blat)|
      ls = 69.0 * Math.cos(lat * Math::PI / 180.0)
      px=(lng-alng)*ls; py=(lat-alat)*69.0
      dx=(blng-alng)*ls; dy=(blat-alat)*69.0
      q=dx*dx+dy*dy
      t = q < 1e-10 ? 0 : [[0.0,(px*dx+py*dy)/q].max,1.0].min
      Math.sqrt((px-t*dx)**2+(py-t*dy)**2)
    end.min
  end.min || 999
end

checks = {
  # Should be COASTAL (< 2 miles from open ocean coast)
  'Miami Beach FL — Atlantic coast'          => { lat: 25.790, lng: -80.130, expect: :coastal },
  'Clearwater Beach FL — Gulf coast'         => { lat: 27.978, lng: -82.827, expect: :coastal },
  'Venice FL — Gulf coast'                   => { lat: 27.099, lng: -82.454, expect: :coastal },
  'Galveston Island TX — Gulf coast'         => { lat: 29.298, lng: -94.794, expect: :coastal },
  'Fort Lauderdale beach — Atlantic'         => { lat: 26.118, lng: -80.102, expect: :coastal },
  'South Padre Island TX — Gulf coast'       => { lat: 26.050, lng: -97.150, expect: :coastal },
  # Borderline — bay-front properties flagged intentionally (coastal influence zone)
  'Brickell Miami — Biscayne Bay front'      => { lat: 25.775, lng: -80.196, expect: :coastal },
  # Should NOT be coastal (> 2 miles from approved open water)
  'Houston TX — far inland'                  => { lat: 29.760, lng: -95.370, expect: :inland },
  'Sarasota city — not Gulf-facing'          => { lat: 27.337, lng: -82.537, expect: :inland },
  'Orlando FL — inland'                      => { lat: 28.538, lng: -81.379, expect: :inland },
  'Dallas TX — far inland'                   => { lat: 32.780, lng: -96.800, expect: :inland },
  # Approved open-water bays / sounds
  'Tampa downtown — Tampa Bay open water'    => { lat: 27.947, lng: -82.458, expect: :coastal },
  'Fort Myers side — San Carlos Bay access'  => { lat: 26.490, lng: -82.030, expect: :coastal },
}

all_pass = true
checks.each do |label, v|
  d    = min_dist_miles(v[:lat], v[:lng], features).round(2)
  flag = d <= 2.0 ? :coastal : :inland
  ok   = flag == v[:expect]
  all_pass = false unless ok
  status = ok ? 'OK ' : 'FAIL'
  puts "  #{status}  #{d.to_s.rjust(5)} mi  #{label}"
end

puts
if all_pass
  puts "All validation checks passed."
else
  puts "WARNING: Some checks failed — review bay exclusion zones in this script."
end
puts

# ---------------------------------------------------------------------------
# AREAWATER — Census TIGER/Line county-level water body polygons
#
# L4150 only traces named "Atlantic" and "Gulf" outer coast segments.
# Charlotte Harbor, Pine Island Sound, Matlacha Pass, San Carlos Bay,
# Estero Bay, and Lemon Bay are entirely absent from L4150 — the same gap
# that would exclude Tampa Bay if it weren't a named Gulf feature.
#
# AREAWATER (H2051 = Bay/Estuary/Sound) gives us the actual polygon
# boundaries for all significant water bodies in each county.
# ---------------------------------------------------------------------------

AREAWATER_COUNTIES = {
  'Sarasota County FL'    => '12115',  # Lemon Bay, Little Sarasota Bay
  'Manatee County FL'     => '12081',  # Anna Maria Sound, northern Sarasota Bay, Terra Ceia Bay
  'Charlotte County FL'   => '12015',  # Charlotte Harbor, Gasparilla Sound
  'Lee County FL'         => '12071',  # Pine Island Sound, Matlacha Pass, San Carlos Bay, Estero Bay, Caloosahatchee
  'Collier County FL'     => '12021',  # Naples Bay
  'Hillsborough County FL' => '12057', # Old Tampa Bay, Hillsborough Bay, Davis Islands, Gandy area
  'Pinellas County FL'    => '12103',  # Boca Ciega Bay, St. Pete inner bay waters
  'Miami-Dade County FL'  => '12086',  # Biscayne Bay — fixes Chicken Key / outer bay coverage
}.freeze

MIN_AWATER_M2 = 2_000_000  # 2 km² minimum — filters tiny ponds, keeps all navigable bays

def download_and_extract(url, stem, files)
  zip_path = File.join(Dir.tmpdir, "#{stem}.zip")
  shp_path = File.join(Dir.tmpdir, "#{stem}.shp")
  unless File.exist?(shp_path)
    print "  Downloading #{stem}... "
    uri  = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true; http.open_timeout = 30; http.read_timeout = 120
    http.start { |h| h.request(Net::HTTP::Get.new(uri)) { |r| File.open(zip_path,'wb'){|f| r.read_body{|c| f.write(c)}} } }
    system("cd #{Dir.tmpdir} && unzip -q -o #{zip_path} #{files.join(' ')} 2>/dev/null")
    puts "done"
  end
  shp_path
end

def parse_dbf_records(dbf_path)
  dbf = File.binread(dbf_path)
  num_records = dbf[4,4].unpack('l<')[0]
  header_size = dbf[8,2].unpack('s<')[0]
  record_size = dbf[10,2].unpack('s<')[0]
  fields = []
  pos = 32
  while pos < header_size - 1
    break if dbf[pos].ord == 13
    fields << { name: dbf[pos,11].gsub("\x00",'').strip, type: dbf[pos+11], len: dbf[pos+16].unpack('C')[0] }
    pos += 32
  end
  (0...num_records).map do |i|
    off = header_size + i * record_size + 1
    foff = 0
    fields.each_with_object({}) do |f, h|
      v = dbf[off+foff, f[:len]].to_s.strip
      h[f[:name]] = f[:type] == 'N' ? v.to_f : v
      foff += f[:len]
    end
  end
end

def parse_areawater_polygons(shp_path, dbf_path, min_area)
  recs = parse_dbf_records(dbf_path)
  shp  = File.binread(shp_path)
  pos  = 100
  idx  = 0
  out  = []
  while pos < shp.size
    content_len = shp[pos+4,4].unpack('N')[0] * 2
    pos += 8
    shape_type = shp[pos,4].unpack('V')[0]
    if shape_type == 5  # Polygon
      rec    = recs[idx] || {}
      mtfcc  = rec['MTFCC'].to_s
      awater = rec['AWATER'].to_f
      name   = rec['FULLNAME'].to_s
      if mtfcc == 'H2051' && awater >= min_area
        num_parts  = shp[pos+36,4].unpack('V')[0]
        num_points = shp[pos+40,4].unpack('V')[0]
        parts      = shp[pos+44, num_parts*4].unpack('V*')
        pts_off    = pos + 44 + num_parts * 4
        all_pts    = (0...num_points).map { |pi| shp[pts_off + pi*16, 16].unpack('EE') }
        (0...num_parts).each do |pi|
          s   = parts[pi]
          e   = (pi+1 < num_parts ? parts[pi+1] : num_points) - 1
          pts = all_pts[s..e]
          next if pts.size < 4
          out << {
            'type'       => 'Feature',
            'properties' => { 'name' => name.empty? ? 'Water body' : name, 'source' => 'areawater', 'mtfcc' => mtfcc },
            'geometry'   => { 'type' => 'LineString', 'coordinates' => pts }
          }
        end
      end
    end
    pos += content_len
    idx += 1
  end
  out
end

puts "Downloading Census TIGER AREAWATER county shapefiles..."
areawater_count = 0
AREAWATER_COUNTIES.each do |county_name, fips|
  stem  = "tl_2023_#{fips}_areawater"
  url   = "https://www2.census.gov/geo/tiger/TIGER2023/AREAWATER/#{stem}.zip"
  files = ["#{stem}.shp", "#{stem}.dbf", "#{stem}.shx"]
  shp_path = download_and_extract(url, stem, files)
  dbf_path = shp_path.sub('.shp', '.dbf')
  feats = parse_areawater_polygons(shp_path, dbf_path, MIN_AWATER_M2)
  puts "  #{county_name}: #{feats.size} bay/estuary features added"
  features.concat(feats)
  areawater_count += feats.size
end
puts "Total AREAWATER features added: #{areawater_count}"
puts

# ---------------------------------------------------------------------------
# Minimal supplemental overrides — only North Pinellas gap fill remains
# (the Charlotte Harbor / Fort Myers system is now fully covered by AREAWATER)
# ---------------------------------------------------------------------------
SUPPLEMENTAL_COASTAL_FEATURES = [

  # ── Caloosahatchee River — tidal/estuarine reach ───────────────────────
  # AREAWATER classifies the Caloosahatchee as H3010 (stream/river), not H2051,
  # so it's excluded from the bay/estuary filter above. The lower tidal reach
  # from the Charlotte Harbor junction east to Fort Myers is navigable open water
  # and waterfront properties here should be flagged COASTAL.
  {
    'type' => 'Feature',
    'properties' => { 'name' => 'Caloosahatchee River — tidal reach (Cape Coral / Fort Myers)', 'source' => 'custom' },
    'geometry' => { 'type' => 'LineString', 'coordinates' => [
      [-81.993, 26.653],  # Charlotte Harbor / river junction (west)
      [-81.970, 26.648],
      [-81.950, 26.644],
      [-81.930, 26.641],
      [-81.910, 26.640],
      [-81.890, 26.640],
      [-81.862, 26.641],  # Downtown Fort Myers / Centennial Park (east)
    ] }
  },

  # ── North Pinellas Gulf coast gap fill ─────────────────────────────────
  # Census L4150 has good coverage at Tarpon Springs (~28.13°N) and at
  # Clearwater Beach (~27.97°N), but the Honeymoon Island / Caladesi Island
  # barrier island stretch in between has a data gap.
  {
    'type' => 'Feature',
    'properties' => { 'name' => 'North Pinellas Gulf coast (Honeymoon Is. / Caladesi Is.)', 'source' => 'custom' },
    'geometry' => { 'type' => 'LineString', 'coordinates' => [
      [-82.820, 28.110],
      [-82.820, 28.095],
      [-82.821, 28.080],
      [-82.822, 28.065],
      [-82.824, 28.050],
      [-82.826, 28.035],
      [-82.828, 28.020],
      [-82.829, 28.005],
      [-82.829, 27.990],
      [-82.829, 27.975],
    ] }
  },

].freeze

features.concat(SUPPLEMENTAL_COASTAL_FEATURES)
puts "Added #{SUPPLEMENTAL_COASTAL_FEATURES.size} supplemental coastal features (North Pinellas gap fill)."
puts

# ---------------------------------------------------------------------------
# Write output
# ---------------------------------------------------------------------------
FileUtils.mkdir_p(File.dirname(OUTPUT_FILE))
geojson = {
  'type'     => 'FeatureCollection',
  'features' => features,
  'metadata' => {
    'source'      => 'US Census Bureau TIGER/Line 2023 - National Coastline (MTFCC L4150)',
    'url'         => 'https://www2.census.gov/geo/tiger/TIGER2023/COASTLINE/',
    'scope'       => 'Florida (Atlantic + Gulf) and Texas (Gulf) outer ocean coast only',
    'generated'   => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
    'note'        => "Bay/estuary/lagoon shorelines filtered out via #{BAY_EXCLUSIONS.size} exclusion zones. " \
                     "Only Census L4150 'Atlantic' and 'Gulf' named features included."
  }
}
File.write(OUTPUT_FILE, JSON.generate(geojson))

interior_geojson = {
  'type'     => 'FeatureCollection',
  'features' => interior_features,
  'metadata' => {
    'source'      => 'US Census Bureau TIGER/Line 2023 - National Coastline (MTFCC L4150)',
    'url'         => 'https://www2.census.gov/geo/tiger/TIGER2023/COASTLINE/',
    'scope'       => 'Florida and Texas interior bay / lagoon candidate shoreline segments',
    'generated'   => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
    'note'        => "Segments inside #{BAY_EXCLUSIONS.size} bay / lagoon exclusion zones, retained as an advisor context layer."
  }
}
File.write(INTERIOR_OUTPUT_FILE, JSON.generate(interior_geojson))
puts "Saved:  #{OUTPUT_FILE}"
puts "Saved:  #{INTERIOR_OUTPUT_FILE}"
puts "Size:   #{(File.size(OUTPUT_FILE) / 1024.0).round(1)} KB"
puts "Size:   #{(File.size(INTERIOR_OUTPUT_FILE) / 1024.0).round(1)} KB"
puts "Segments: #{features.size}"
puts "Interior segments: #{interior_features.size}"
puts
puts "Setup complete. Start the app with:  bundle exec ruby app.rb"
