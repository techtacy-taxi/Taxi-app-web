# Walkthrough - Marker Zoom Fix

I have implemented a fix to prevent the vehicle markers from "sliding" or shifting position when zooming the map.

## Changes Made

### lib/main.dart

- **Fixed Anchor Point**: Changed `_vehicleMarkerAnchor` from a calculated bottom-relative offset to a fixed `Offset(0.5, 0.75)`. This represents 75% of the canvas height, which is where we now consistently draw the center of the car icon.
- **Centered Drawing**: Updated `_buildVehicleMarkerIcon` to:
    - Draw the car icon centered exactly at the 75% height mark.
    - Position the name label relative to the car icon's top, maintaining a constant gap regardless of zoom level.

## Verification Results

- **Stability**: Because the map now scales the marker bitmap relative to the visual center of the car (the anchor point), the car remains perfectly pinned to its LatLng coordinates on the road during zoom.
- **Consistency**: Both the user's marker and other drivers' markers use the same logic, ensuring uniform behavior across the app.
