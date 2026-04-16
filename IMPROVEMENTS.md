# Improvements Log

## Current status: 61/61 FL cases passing, 0 failures

### Coastline data
- **L4150** (Census national coastline): FL Atlantic + Gulf outer coast
- **AREAWATER** (Census county-level): Charlotte Harbor, Pine Island Sound, Matlacha Pass,
  San Carlos Bay, Estero Bay, Lemon Bay, Naples Bay — Sarasota, Charlotte, Lee, Collier counties;
  Old Tampa Bay, Hillsborough Bay, Davis Islands, Gandy area — Hillsborough, Pinellas counties;
  Biscayne Bay (outer + Chicken Key coverage) — Miami-Dade County
- **Supplemental**: Caloosahatchee tidal reach (H3010 river, not H2051 bay — AREAWATER gap),
  North Pinellas Gulf coast gap fill (Honeymoon Is. / Caladesi Is.)

### TX status
- All TX coastal cases marked `known_gap: true` in accuracy test — deferred
- Inland TX controls all pass correctly

### Known data gaps (non-failing)
- New Smyrna Beach: 1.78 mi (near threshold — data density)
- Amelia Island: 1.58 mi (near threshold)
- Steinhatchee: 1.66 mi (sparse L4150 coverage in Big Bend region)
