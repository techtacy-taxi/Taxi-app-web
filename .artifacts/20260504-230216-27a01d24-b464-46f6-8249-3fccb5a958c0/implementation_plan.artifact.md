# Initial Map View and Marker Fixes

The goal is twofold:
1. Fix the vehicle marker shifting issue (completed).
2. Set the initial map view to cover the entire Attica region at startup.

## Proposed Changes for Initial View

### main.dart (file:///C:/Users/rs125/Desktop/My_Taxi_App/my_taxi_app/lib/main.dart)

- Update `_athens` constant to center on Attica with a wider zoom level.
- Ensure `GoogleMap` uses this constant for its `initialCameraPosition`.
- Adjust `_startLocationUpdates` to avoid force-centering the camera on the user's location immediately at startup, so the Attica view is preserved.

#### Detailed Logic:

1.  **Update `_athens` constant**:
    ```dart
    static const CameraPosition _athens = CameraPosition(
      target: LatLng(38.0, 23.85), // Approximate center of Attica
      zoom: 9.0, // Zoom level to see the whole region
    );
    ```

2.  **Update `GoogleMap` Widget**:
    Ensure it starts with `_athens`.

3.  **Prevent Auto-Snap to User**:
    In `_startLocationUpdates`, we'll keep the location tracking but remove the `animateCamera` call that snaps to the user on the first location fix, or make it optional.

## Verification Plan

### Manual Verification
- Launch the app.
- Verify that the map starts showing the entire Attica region.
- Verify that zooming in/out doesn't shift markers (from previous task).
