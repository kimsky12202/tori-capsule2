import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:image_picker/image_picker.dart' as img_picker;
import 'package:exif/exif.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'fog_painter.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:ui' show ImageByteFormat, PictureRecorder;
import 'dart:typed_data';
import 'dart:io';
import 'dart:math' as math;

class CapsulePin {
  final String id;
  final double lat;
  final double lng;
  final String? photoPath;
  final String title;

  CapsulePin({
    required this.id,
    required this.lat,
    required this.lng,
    this.photoPath,
    required this.title,
  });

  File? get photo => photoPath != null ? File(photoPath!) : null;

  Map<String, dynamic> toJson() => {
    'id': id,
    'lat': lat,
    'lng': lng,
    'photoPath': photoPath,
    'title': title,
  };

  factory CapsulePin.fromJson(Map<String, dynamic> j) => CapsulePin(
    id: j['id'] as String,
    lat: (j['lat'] as num).toDouble(),
    lng: (j['lng'] as num).toDouble(),
    photoPath: j['photoPath'] as String?,
    title: j['title'] as String,
  );
}

// ignore: deprecated_member_use
class _AnnotationTapListener implements OnPointAnnotationClickListener {
  final void Function(PointAnnotation) onTap;
  _AnnotationTapListener(this.onTap);

  @override
  void onPointAnnotationClick(PointAnnotation annotation) => onTap(annotation);
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => MapScreenState();
}

class MapScreenState extends State<MapScreen>
    with AutomaticKeepAliveClientMixin {
  static const String _token = String.fromEnvironment('MAPBOX_ACCESS_TOKEN');
  static const String _prefsKey = 'capsule_pins';

  MapboxMap? _map;
  PointAnnotationManager? _pinManager;
  PointAnnotationManager? _myLocManager;
  PointAnnotation? _myLocMarker;

  final List<CapsulePin> _pins = [];
  final Map<String, String> _markerMap = {};
  final img_picker.ImagePicker _picker = img_picker.ImagePicker();
  StreamSubscription<geo.Position>? _posSub;

  List<Offset> _fogPositions = [];
  bool _isLoading = false;
  bool _tapListenerRegistered = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    MapboxOptions.setAccessToken(_token);
  }

  @override
  void dispose() {
    _posSub?.cancel();
    super.dispose();
  }

  // ── 그라데이션 안개 위치 업데이트 ──────────────────────────
  Future<void> _updateFogPositions() async {
    if (_map == null || !mounted) return;
    final positions = <Offset>[];
    for (final pin in _pins) {
      try {
        final coord = await _map!.pixelForCoordinate(
          Point(coordinates: Position(pin.lng, pin.lat)),
        );
        positions.add(Offset(coord.x, coord.y));
      } catch (_) {}
    }
    if (mounted) setState(() => _fogPositions = positions);
  }

  // ── 저장/불러오기 ─────────────────────────────────────────
  Future<void> _savePins() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _pins.map((p) => jsonEncode(p.toJson())).toList();
    await prefs.setStringList(_prefsKey, list);
  }

  Future<void> _loadPins() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_prefsKey) ?? [];
    for (final raw in list) {
      try {
        final pin = CapsulePin.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        if (pin.photoPath == null || File(pin.photoPath!).existsSync()) {
          _pins.add(pin);
          await _addMarkerToMap(pin);
        }
      } catch (_) {}
    }
    await _updateFogPositions();
  }

  Future<void> _addMarkerToMap(CapsulePin pin) async {
    _pinManager ??= await _map?.annotations.createPointAnnotationManager();
    Uint8List markerImg;
    if (pin.photo != null && pin.photo!.existsSync()) {
      markerImg = await _makePhotoMarker(pin.photo!);
    } else {
      markerImg = await _makeDotImage(color: const Color(0xFF7B5EA7));
    }
    final marker = await _pinManager?.create(
      PointAnnotationOptions(
        geometry: Point(coordinates: Position(pin.lng, pin.lat)),
        image: markerImg,
        iconSize: 0.8,
      ),
    );
    if (marker != null) _markerMap[pin.id] = marker.id;
    _registerTapListener();
  }

  // ── 3D 건물 레이어 ───────────────────────────────────────
  Future<void> _add3DBuildings() async {
    if (_map == null) return;
    try {
      final exists = await _map!.style.styleLayerExists('3d-buildings');
      if (exists) return;
      await _map!.style.addLayer(
        FillExtrusionLayer(
          id: '3d-buildings',
          sourceId: 'composite',
          sourceLayer: 'building',
          fillExtrusionOpacity: 0.75,
          fillExtrusionColor: const Color(0xFF1C1C2E).value,
          fillExtrusionAmbientOcclusionIntensity: 0.3,
        ),
      );
      await _map!.style.setStyleLayerProperty(
        '3d-buildings',
        'fill-extrusion-height',
        jsonEncode([
          'interpolate', ['linear'], ['zoom'],
          15, 0, 15.05, ['get', 'height'],
        ]),
      );
      await _map!.style.setStyleLayerProperty(
        '3d-buildings',
        'fill-extrusion-base',
        jsonEncode([
          'interpolate', ['linear'], ['zoom'],
          15, 0, 15.05, ['get', 'min_height'],
        ]),
      );
    } catch (e) {
      debugPrint('3D 건물 오류: $e');
    }
  }

  // ── 지도 초기화 ───────────────────────────────────────────
  Future<void> _onMapCreated(MapboxMap map) async {
    _map = map;
    map.gestures.updateSettings(
      GesturesSettings(
        rotateEnabled: true,
        pinchToZoomEnabled: true,
        scrollEnabled: true,
        doubleTapToZoomInEnabled: true,
        doubleTouchToZoomOutEnabled: true,
        quickZoomEnabled: true,
      ),
    );
    await _add3DBuildings();
    await _moveToMyLocation();
    _startTracking();
    await _loadPins();
  }

  Future<void> _onStyleLoaded(StyleLoadedEventData _) async {
    await _add3DBuildings();
    await _updateFogPositions();
  }

  Future<void> _moveToMyLocation() async {
    try {
      geo.LocationPermission perm = await geo.Geolocator.checkPermission();
      if (perm == geo.LocationPermission.denied) {
        perm = await geo.Geolocator.requestPermission();
      }
      final pos = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.high,
        ),
      );
      _map?.flyTo(
        CameraOptions(
          center: Point(coordinates: Position(pos.longitude, pos.latitude)),
          zoom: 16.0,
          pitch: 45.0,
        ),
        MapAnimationOptions(duration: 1000),
      );
      await _updateMyDot(pos.latitude, pos.longitude);
    } catch (e) {
      debugPrint('위치 오류: $e');
    }
  }

  Future<void> _updateMyDot(double lat, double lng) async {
    _myLocManager ??= await _map?.annotations.createPointAnnotationManager();
    if (_myLocMarker != null) {
      await _myLocManager?.delete(_myLocMarker!);
      _myLocMarker = null;
    }
    _myLocMarker = await _myLocManager?.create(
      PointAnnotationOptions(
        geometry: Point(coordinates: Position(lng, lat)),
        image: await _makeDotImage(color: const Color(0xFF4A90E2)),
        iconSize: 1.0,
      ),
    );
  }

  Future<Uint8List> _makeDotImage({required Color color}) async {
    final rec = PictureRecorder();
    final c = Canvas(rec, const Rect.fromLTWH(0, 0, 40, 40));
    c.drawCircle(const Offset(20, 20), 18, Paint()..color = Colors.white);
    c.drawCircle(const Offset(20, 20), 13, Paint()..color = color);
    final img = await rec.endRecording().toImage(40, 40);
    final d = await img.toByteData(format: ImageByteFormat.png);
    return d!.buffer.asUint8List();
  }

  void _startTracking() {
    _posSub = geo.Geolocator.getPositionStream(
      locationSettings: const geo.LocationSettings(
        accuracy: geo.LocationAccuracy.high,
        distanceFilter: 15,
      ),
    ).listen((p) => _updateMyDot(p.latitude, p.longitude));
  }

  // ── GPS EXIF 추출 ─────────────────────────────────────────
  Future<(geo.Position?, String)> _extractGpsFromBytes(
      Uint8List bytes) async {
    try {
      final data = await readExifFromBytes(bytes);
      if (data.isEmpty) {
        return (null, 'EXIF 데이터가 없어요. 카메라로 직접 찍은 사진을 써보세요.');
      }
      if (!data.containsKey('GPS GPSLatitude') ||
          !data.containsKey('GPS GPSLongitude')) {
        return (
          null,
          'GPS 정보가 없어요. 카메라 설정에서 "위치 태그"를 켜고 직접 찍은 사진을 써보세요.',
        );
      }

      double? parseDMS(IfdTag tag) {
        final vals = tag.values.toList();
        if (vals.length < 3) return null;
        final deg = _toDouble(vals[0]);
        final min = _toDouble(vals[1]);
        final sec = _toDouble(vals[2]);
        if (deg == null || min == null || sec == null) return null;
        return deg + min / 60.0 + sec / 3600.0;
      }

      double? lat = parseDMS(data['GPS GPSLatitude']!);
      double? lng = parseDMS(data['GPS GPSLongitude']!);
      if (lat == null || lng == null || (lat == 0.0 && lng == 0.0)) {
        return (null, 'GPS 값을 읽을 수 없어요.');
      }
      if (data['GPS GPSLatitudeRef']?.printable == 'S') lat = -lat;
      if (data['GPS GPSLongitudeRef']?.printable == 'W') lng = -lng;

      return (
        geo.Position(
          latitude: lat,
          longitude: lng,
          timestamp: DateTime.now(),
          accuracy: 0,
          altitude: 0,
          altitudeAccuracy: 0,
          heading: 0,
          headingAccuracy: 0,
          speed: 0,
          speedAccuracy: 0,
        ),
        '',
      );
    } catch (e) {
      return (null, 'EXIF 읽기 오류: $e');
    }
  }

  double? _toDouble(dynamic val) {
    try {
      final n = (val as dynamic).numerator;
      final d = (val as dynamic).denominator;
      if (d == 0) return 0.0;
      return (n as num).toDouble() / (d as num).toDouble();
    } catch (_) {}
    try {
      if (val is num) return val.toDouble();
    } catch (_) {}
    try {
      final s = val.toString().trim();
      if (s.contains('/')) {
        final parts = s.split('/');
        final n = double.tryParse(parts[0]) ?? 0.0;
        final d = double.tryParse(parts[1]) ?? 1.0;
        if (d == 0) return 0.0;
        return n / d;
      }
      return double.tryParse(s);
    } catch (_) {}
    return null;
  }

  Future<Uint8List> _makePhotoMarker(File photo) async {
    final bytes = await photo.readAsBytes();
    // EXIF orientation 읽기
    final exifData = await readExifFromBytes(bytes);
    int orientation = 1;
    final orientTag = exifData['Image Orientation'];
    if (orientTag != null) {
      orientation =
          int.tryParse(orientTag.printable.split(' ').first) ?? 1;
    }

    final image = await decodeImageFromList(bytes);
    const double sz = 140, pad = 10;
    final rec = PictureRecorder();
    final c = Canvas(rec, Rect.fromLTWH(0, 0, sz, sz + 20));

    final tail = Path()
      ..moveTo(sz / 2 - 10, sz - 4)
      ..lineTo(sz / 2, sz + 20)
      ..lineTo(sz / 2 + 10, sz - 4)
      ..close();
    c.drawPath(tail, Paint()..color = const Color(0xFF7B5EA7));
    c.drawCircle(
      Offset(sz / 2, sz / 2),
      sz / 2 - 2,
      Paint()..color = const Color(0xFF7B5EA7),
    );
    c.clipPath(
      Path()..addOval(
        Rect.fromCircle(
            center: Offset(sz / 2, sz / 2), radius: sz / 2 - pad),
      ),
    );

    // EXIF 회전 보정 적용
    c.save();
    c.translate(sz / 2, sz / 2);
    if (orientation == 3) {
      c.rotate(math.pi);
    } else if (orientation == 6) {
      c.rotate(math.pi / 2);
    } else if (orientation == 8) {
      c.rotate(-math.pi / 2);
    }
    c.translate(-sz / 2, -sz / 2);

    final sw = image.width.toDouble(), sh = image.height.toDouble();
    final ms = math.min(sw, sh);
    c.drawImageRect(
      image,
      Rect.fromCenter(
          center: Offset(sw / 2, sh / 2), width: ms, height: ms),
      Rect.fromLTWH(pad, pad, sz - pad * 2, sz - pad * 2),
      Paint(),
    );
    c.restore();

    final out =
        await rec.endRecording().toImage(sz.toInt(), (sz + 20).toInt());
    final d = await out.toByteData(format: ImageByteFormat.png);
    return d!.buffer.asUint8List();
  }

  void _registerTapListener() {
    if (_tapListenerRegistered || _pinManager == null) return;
    // ignore: deprecated_member_use
    _pinManager!.addOnPointAnnotationClickListener(
      _AnnotationTapListener((PointAnnotation tapped) {
        final pinId = _markerMap.entries
            .firstWhere(
              (e) => e.value == tapped.id,
              orElse: () => const MapEntry('', ''),
            )
            .key;
        if (pinId.isEmpty) return;
        final p = _pins.firstWhere(
          (p) => p.id == pinId,
          orElse: () => CapsulePin(id: '', lat: 0, lng: 0, title: ''),
        );
        if (p.id.isNotEmpty) _showPinSheet(p);
      }),
    );
    _tapListenerRegistered = true;
  }

  // ── 사진 추가 ─────────────────────────────────────────────
  Future<void> addPhotoPin() async {
    if (!await Permission.accessMediaLocation.isGranted) {
      await Permission.accessMediaLocation.request();
    }
    if (!await Permission.photos.isGranted) {
      await Permission.photos.request();
    }

    final picked = await _picker.pickImage(
      source: img_picker.ImageSource.gallery,
      requestFullMetadata: true,
    );
    if (picked == null) return;
    final file = File(picked.path);
    setState(() => _isLoading = true);
    try {
      final rawBytes = await picked.readAsBytes();
      final (gpsResult, gpsMessage) = await _extractGpsFromBytes(rawBytes);
      geo.Position? gpsPos = gpsResult;

      if (gpsPos == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('📍 $gpsMessage\n현재 위치를 대신 사용해요.'),
              duration: const Duration(seconds: 4),
            ),
          );
        }
        gpsPos = await geo.Geolocator.getCurrentPosition(
          locationSettings: const geo.LocationSettings(
            accuracy: geo.LocationAccuracy.high,
          ),
        );
      }

      final pin = CapsulePin(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        lat: gpsPos.latitude,
        lng: gpsPos.longitude,
        photoPath: file.path,
        title: '타임캡슐 ${_pins.length + 1}',
      );
      _pins.add(pin);
      await _addMarkerToMap(pin);
      await _savePins();

      await _map?.flyTo(
        CameraOptions(
          center: Point(
            coordinates: Position(gpsPos.longitude, gpsPos.latitude),
          ),
          zoom: 18.5,
          pitch: 65.0,
          bearing: 0.0,
        ),
        MapAnimationOptions(duration: 1800),
      );

      await _updateFogPositions();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('오류: $e')));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showPinSheet(CapsulePin pin) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFFFAF9F6),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFD6D1C4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            if (pin.photo != null && pin.photo!.existsSync())
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  pin.photo!,
                  height: 200,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
            const SizedBox(height: 16),
            Text(
              pin.title,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Color(0xFF2E2B2A),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '📍 ${pin.lat.toStringAsFixed(5)}, ${pin.lng.toStringAsFixed(5)}',
              style: const TextStyle(color: Color(0xFF7A756D), fontSize: 13),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      body: Stack(
        children: [
          MapWidget(
            key: const ValueKey('capsule_map'),
            styleUri: 'mapbox://styles/mapbox/dark-v11',
            cameraOptions: CameraOptions(
              center: Point(coordinates: Position(127.2890, 36.4800)),
              zoom: 6.0,
              pitch: 45.0,
            ),
            onMapCreated: _onMapCreated,
            onStyleLoadedListener: _onStyleLoaded,
            onCameraChangeListener: (_) => _updateFogPositions(),
          ),
          // 그라데이션 안개 오버레이
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: GradientFogPainter(
                  positions: _fogPositions,
                  clearRadius: 190,
                ),
              ),
            ),
          ),
          if (_isLoading)
            Container(
              color: Colors.black26,
              child: const Center(
                child: CircularProgressIndicator(color: Color(0xFF7B5EA7)),
              ),
            ),
          Positioned(
            bottom: 100,
            right: 16,
            child: _MapFab(
              heroTag: 'photo',
              backgroundColor: const Color(0xFF7B5EA7),
              icon: Icons.add_photo_alternate,
              onPressed: addPhotoPin,
            ),
          ),
          Positioned(
            bottom: 30,
            right: 16,
            child: _MapFab(
              heroTag: 'location',
              backgroundColor: Colors.white,
              iconColor: const Color(0xFF7B5EA7),
              icon: Icons.my_location,
              onPressed: _moveToMyLocation,
            ),
          ),
        ],
      ),
    );
  }
}

class _MapFab extends StatelessWidget {
  final String heroTag;
  final Color backgroundColor;
  final Color iconColor;
  final IconData icon;
  final VoidCallback onPressed;

  const _MapFab({
    required this.heroTag,
    required this.backgroundColor,
    required this.icon,
    required this.onPressed,
    this.iconColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(16),
      elevation: 4,
      shadowColor: Colors.black26,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onPressed,
        child: SizedBox(
          width: 56,
          height: 56,
          child: Icon(icon, color: iconColor, size: 24),
        ),
      ),
    );
  }
}
