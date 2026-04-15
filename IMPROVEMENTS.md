# Improvements Log — Pending Test

## Changes made (not yet fully verified — credits ran out mid-session)

### UI Fix
- `app.rb`: Fixed `showResult()` so the result badge and card update BEFORE map drawing.
  Previously any map draw error silently left the stale "NOT_COASTAL" badge on screen even
  when the API correctly returned COASTAL. Card now always updates; map draw is best-effort
  in a try-catch.

### Accuracy Test
- `bin/accuracy_test.rb` (NEW): Full geographic accuracy test — ~66 cases spanning FL
  Atlantic, FL Gulf, FL panhandle, TX Gulf (deferred), FL inland controls, TX inland controls.
  Run with: `bundle exec ruby bin/accuracy_test.rb`

### Bay Exclusion Zone Tuning (`bin/setup_coastline.rb`)
- Indian River Lagoon: split into 2 narrower bands so Atlantic beaches (Cocoa, New Smyrna)
  are no longer clipped
- Florida Bay: southern boundary raised so Marathon / Sombrero Beach passes
- Apalachicola Bay: southern boundary raised so St. George Island passes
- Choctawhatchee Bay: southern boundary raised so Destin / Fort Walton Beach pass
- Pensacola Bay: southern boundary raised so Navarre Beach / Pensacola Beach pass
- Galveston Bay: southern boundary raised so Bolivar Peninsula passes
- Matagorda Bay / Corpus Christi Bay: boundaries tightened

### Supplemental Coastline Segments (Charlotte Harbor / Fort Myers system)
Census TIGER L4150 has NO data for inner water bodies. Six custom LineString segments added
to `setup_coastline.rb` and baked into `data/coastline.geojson`:

| Segment | Status |
|---|---|
| Charlotte Harbor eastern shore (Punta Gorda → Cape Coral) | ✅ passing |
| Caloosahatchee River north bank (Cape Coral → Edison Bridge) | ✅ passing (1.63 mi warning) |
| Gasparilla Sound — island east shore (Boca Grande barrier island) | ✅ passing |
| Gasparilla Sound — mainland west shore (Placida / Cape Haze) | ✅ passing |
| Pine Island Sound / Matlacha Pass eastern shore | ❌ still failing — coords need adjustment |
| North Pinellas Gulf coast gap fill (Honeymoon Is. / Caladesi Is.) | needs test case added |

## Testing needed when credits return
1. `bundle exec ruby bin/accuracy_test.rb` — currently 1 failure:
   - **Pine Island (Matlacha Pass side)** at (26.631, -82.098) → NOT_COASTAL
     The supplemental Pine Island Sound segment coordinates may need adjustment
     or the test coordinate may need to move closer to the segment.
2. Verify Honeymoon Island / Caladesi Island gap fill in the browser overlay
3. Restart app server after any setup re-run: `bundle exec ruby app.rb`
