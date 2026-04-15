#!/usr/bin/env ruby

require_relative '../app'

checks = [
  {
    label: 'Miami Beach open coast',
    lat: 25.790,
    lng: -80.130,
    expect: 'COASTAL',
    distance_max: 2.0
  },
  {
    label: 'Houston inland',
    lat: 29.760,
    lng: -95.370,
    expect: 'NOT_COASTAL'
  },
  {
    label: 'Tampa Bay open water',
    lat: 27.947,
    lng: -82.458,
    expect: 'COASTAL',
    distance_max: 2.0
  },
  {
    label: 'Fort Myers side open water',
    lat: 26.490,
    lng: -82.030,
    expect: 'COASTAL',
    distance_max: 2.0
  },
  {
    label: 'Orlando inland',
    lat: 28.538,
    lng: -81.379,
    expect: 'NOT_COASTAL'
  }
]

failures = []

puts 'Coastal Checker bug check'
puts

checks.each do |check|
  result = evaluate_coords(check[:lat], check[:lng], check[:label])
  ok = result[:result] == check[:expect]
  if ok && check[:distance_max]
    ok = result[:distance_mi] && result[:distance_mi] <= check[:distance_max]
  end
  if ok && check[:expect] == 'COASTAL'
    ok = !result[:coastline_point].nil?
  end

  status = ok ? 'PASS' : 'FAIL'
  distance = result[:distance_mi] ? "#{result[:distance_mi]} mi" : 'n/a'
  puts "#{status.ljust(4)}  #{check[:label]}  ->  #{result[:result]}  (#{distance})"
  failures << [check, result] unless ok
end

puts
if failures.empty?
  puts 'All 5 checks passed.'
  exit 0
else
  puts "#{failures.size} check(s) failed:"
  failures.each do |check, result|
    puts "- #{check[:label]} expected #{check[:expect]}, got #{result[:result]} (#{result[:reason]})"
  end
  exit 1
end
