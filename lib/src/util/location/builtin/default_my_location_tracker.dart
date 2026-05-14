import "package:flutter/services.dart";
import "package:flutter_naver_map/flutter_naver_map.dart";
import "default_my_location_tracker_platform_impl.dart";

class NDefaultMyLocationTracker extends NMyLocationTracker
    with NDefaultMyLocationTrackerPlatformImplMixin {
  final NDefaultMyLocationTrackerOptions options;
  final Function(bool isForeverDenied)? onPermissionDenied;

  NDefaultMyLocationTracker({
    this.options = const NDefaultMyLocationTrackerOptions(),
    this.onPermissionDenied,
  });

  @override
  Future<NLatLng?> startLocationService() async {
    final permissionStatus = await requestLocationPermission();
    switch (permissionStatus) {
      case NDefaultMyLocationTrackerPermissionStatus.granted:
        try {
          return await getCurrentPositionOnce();
        } on PlatformException {
          // Native side occasionally fails to produce a position (e.g.
          // returns "Location is null" when the OS hasn't yielded a fix
          // yet, or right after location services are toggled). The
          // startLocationService contract permits null, and _startTracking
          // already guards on null, so propagating PlatformException here
          // only leaks the failure to the framework's error handler.
          return null;
        }
      case NDefaultMyLocationTrackerPermissionStatus.denied ||
            NDefaultMyLocationTrackerPermissionStatus.deniedForever:
        onPermissionDenied?.call(permissionStatus ==
            NDefaultMyLocationTrackerPermissionStatus.deniedForever);
        return null;
    }
  }

  @override
  void disposeLocationService() {}

  @override
  Stream<NLatLng> get locationStream => getLocationStream();

  @override
  Stream<double> get headingStream => getHeadingStream();
}

class NDefaultMyLocationTrackerOptions {
  const NDefaultMyLocationTrackerOptions();
}
