#!/usr/bin/env ruby

require 'json'
require 'net/http'
require 'uri'

BASE_URL = URI((ENV['APP_URL'] || 'http://localhost:4567').rstrip)

def fetch(path)
  uri = BASE_URL + path
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
    http.get(uri.request_uri)
  end
  raise "HTTP #{res.code} for #{path}" unless res.is_a?(Net::HTTPSuccess)
  res.body
end

def assert(condition, message)
  raise message unless condition
end

def parse_json(path)
  JSON.parse(fetch(path))
end

puts "Deploy smoke test against #{BASE_URL}"

home = fetch('/')
assert(home.include?('Coastal Check'), 'Home page did not load')

coast = parse_json('/coastline.geojson')
interior = parse_json('/interior_water.geojson')
assert(coast['features'].is_a?(Array) && !coast['features'].empty?, 'Open-coast overlay is empty')
assert(interior['features'].is_a?(Array) && !interior['features'].empty?, 'Interior-water overlay is empty')

miami = parse_json('/api/check_coords?lat=25.790&lng=-80.130')
assert(miami['result'] == 'COASTAL', 'Miami Beach should be coastal')
assert(miami['coastline_point'], 'Open-coast anchor missing from response')

orlando = parse_json('/api/check_coords?lat=28.538&lng=-81.379')
assert(orlando['result'] == 'NOT_COASTAL', 'Orlando should not be coastal')

if ENV['SMOKE_ADDRESS'] && !ENV['SMOKE_ADDRESS'].strip.empty?
  address = URI.encode_www_form_component(ENV['SMOKE_ADDRESS'].strip)
  search = parse_json("/api/check?address=#{address}")
  assert(%w[COASTAL NOT_COASTAL OUT_OF_AREA UNKNOWN].include?(search['result']), 'Search API returned an unexpected result')
end

browser_key = ENV['GOOGLE_MAPS_BROWSER_KEY'].to_s.strip
server_key = ENV['GOOGLE_MAPS_SERVER_KEY'].to_s.strip
legacy_key = ENV['GOOGLE_MAPS_API_KEY'].to_s.strip
if !browser_key.empty? && !server_key.empty? && browser_key != server_key
  assert(home.include?(browser_key), 'Browser key is not present in the page source')
  assert(!home.include?(server_key), 'Server key leaked into the page source')
end

if browser_key.empty? && legacy_key.empty?
  puts 'Note: browser key not set, so the Google Maps JS load path was not validated.'
end

puts 'Smoke test passed.'
