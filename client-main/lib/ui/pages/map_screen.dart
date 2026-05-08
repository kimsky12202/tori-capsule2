import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:image_picker/image_picker.dart' as img_picker;
import 'package:exif/exif.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_unity_widget/flutter_unity_widget.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:ui' as ui;
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

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => MapScreenState();
}

// ignore: deprecated_member_use
class MapScreenState extends State<MapScreen>
    with AutomaticKeepAliveClientMixin
    // ignore: deprecated_member_use
    implements OnPointAnnotationClickListener {
  static const String _prefsKey = 'capsule_pins';
  static const String _polygonsKey = 'capsule_polygons_v11';
  static const String _styleUri = 'mapbox://styles/mapbox/streets-v12';

  MapboxMap? _mapboxMap;
  PointAnnotationManager? _annotationManager;
  UnityWidgetController? _unityController;
  bool _unityReady = false;

  final Map<String, PointAnnotation> _annotationMap = {};
  final Map<String, String> _annotationIdToPinId = {};
  PointAnnotation? _myLocAnnotation;

  final List<CapsulePin> _pins = [];
  final Map<String, List<List<List<double>>>> _buildingPolygons = {};
  final img_picker.ImagePicker _picker = img_picker.ImagePicker();
  StreamSubscription<geo.Position>? _posSub;

  bool _isLoading = false;
  Timer? _fogUpdateTimer;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _posSub?.cancel();
    _fogUpdateTimer?.cancel();
    _unityController?.dispose();
    super.dispose();
  }

  // ── Unity callbacks ───────────────────────────────────────
  void _onUnityCreated(UnityWidgetController controller) {
    _unityController = controller;
  }

  void _onUnityMessage(dynamic message) {}

  void _onUnitySceneLoaded(SceneLoaded? scene) {
    _unityReady = true;
    _scheduleFogUpdate();
  }


  void _scheduleFogUpdate() {
    _fogUpdateTimer?.cancel();
    _fogUpdateTimer = Timer(const Duration(milliseconds: 200), _sendFogToUnity);
  }

  Future<void> _sendFogToUnity() async {
    if (!_unityReady || _unityController == null || _mapboxMap == null) return;

    // 현재 카메라 상태를 Unity에 전송 (GeoToUV 계산에 필요)
    try {
      final cam = await _mapboxMap!.getCameraState();
      final center = cam.center;
      _unityController!.postMessage(
        'FogController',
        'UpdateCamera',
        jsonEncode({
          'lat': center.coordinates.lat.toDouble(),
          'lng': center.coordinates.lng.toDouble(),
          'zoom': cam.zoom,
        }),
      );
    } catch (e) {
      debugPrint('UpdateCamera 오류: $e');
    }

    // 폴리곤과 핀 중심을 geo 좌표로 전송
    final polys = _buildingPolygons.values.expand((v) => v).map((poly) {
      return poly.map((pt) => {'lat': pt[1], 'lng': pt[0]}).toList();
    }).toList();
    final centers = _pins.map((p) => {'lat': p.lat, 'lng': p.lng}).toList();

    _unityController!.postMessage(
      'FogController',
      'UpdateFog',
      jsonEncode({'polygons': polys, 'centers': centers}),
    );
  }

  @override
  // ignore: deprecated_member_use
  bool onPointAnnotationClick(PointAnnotation annotation) {
    final pinId = _annotationIdToPinId[annotation.id];
    if (pinId == null || pinId.isEmpty) return true;
    final p = _pins.firstWhere(
      (p) => p.id == pinId,
      orElse: () => CapsulePin(id: '', lat: 0, lng: 0, title: ''),
    );
    if (p.id.isNotEmpty) _showPinSheet(p);
    return true;
  }

  // ── Overpass / polygon helpers ────────────────────────────
  Future<List<List<List<double>>>> _queryStreetBuildings(
      double lat, double lng) async {
    final campusWayQuery = '''
[out:json];
is_in($lat,$lng)->.a;
(
  way(pivot.a)["amenity"~"university|college|school|hospital|kindergarten"];
  way(pivot.a)["landuse"~"education|university"];
);
out geom;
''';
    final campusWay = await _fetchPolygons(campusWayQuery, tag: 'campusWay');
    if (campusWay.isNotEmpty) return campusWay;

    final campusRelQuery = '''
[out:json];
is_in($lat,$lng)->.a;
(
  rel(pivot.a)["amenity"~"university|college|school|hospital|kindergarten"];
  rel(pivot.a)["landuse"~"education|university"];
)->.r;
way(r:"outer");
out geom;
''';
    final campusRel = await _fetchPolygons(campusRelQuery, tag: 'campusRel');
    if (campusRel.isNotEmpty) return campusRel;

    final nearbyQuery = '''
[out:json];
(
  way["amenity"~"university|college|school|hospital"](around:300,$lat,$lng);
  way["landuse"~"education|university"](around:300,$lat,$lng);
);
out geom;
''';
    final nearbyBoundary =
        await _fetchPolygons(nearbyQuery, tag: 'nearbyBoundary');
    if (nearbyBoundary.isNotEmpty) return nearbyBoundary;

    final aptQuery = '''
[out:json];
is_in($lat,$lng)->.a;
(
  way(pivot.a)["landuse"~"residential"]["name"];
  way(pivot.a)["building"~"apartments"]["name"];
);
out geom;
''';
    final aptBoundary = await _fetchPolygons(aptQuery, tag: 'apt');
    if (aptBoundary.isNotEmpty) return aptBoundary;

    final streetQuery = '''
[out:json];
way(around:60,$lat,$lng)["highway"]["name"]->.street;
way["building"](around.street:40);
out geom;
''';
    final streetBuildings =
        await _fetchPolygons(streetQuery, tag: 'street', maxSizeMeters: 200);
    if (streetBuildings.isNotEmpty) return streetBuildings;

    final isInQuery =
        '[out:json];is_in($lat,$lng)->.a;way["building"](pivot.a);out geom;';
    final isInBuildings =
        await _fetchPolygons(isInQuery, tag: 'isin', maxSizeMeters: 200);
    if (isInBuildings.isNotEmpty) return isInBuildings;

    return [_makeCirclePolygon(lat, lng, 25)];
  }

  Future<List<List<List<double>>>> _fetchPolygons(String query,
      {String tag = '', double? maxSizeMeters}) async {
    try {
      final url = Uri.parse(
        'https://overpass-api.de/api/interpreter?data=${Uri.encodeComponent(query)}',
      );
      final res = await http.get(url, headers: {
        'User-Agent': 'tori-capsule/1.0 (Flutter)',
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 25));
      if (res.statusCode != 200) return [];
      final elements =
          (jsonDecode(res.body) as Map)['elements'] as List? ?? [];

      final polys = <List<List<double>>>[];
      for (final el in elements) {
        final geom = (el as Map)['geometry'] as List?;
        if (geom == null || geom.length < 3) continue;
        final poly = geom
            .map((n) => [
                  (n['lon'] as num).toDouble(),
                  (n['lat'] as num).toDouble(),
                ])
            .toList();
        if (maxSizeMeters != null && _polyBboxMeters(poly) > maxSizeMeters) {
          continue;
        }
        polys.add(_simplifyPolygon(poly,
            max: maxSizeMeters == null ? 64 : 28));
      }
      return polys;
    } catch (e) {
      debugPrint('Overpass[$tag] 오류: $e');
      return [];
    }
  }

  double _polyBboxMeters(List<List<double>> poly) {
    double minLat = poly[0][1], maxLat = poly[0][1];
    double minLng = poly[0][0], maxLng = poly[0][0];
    for (final pt in poly) {
      if (pt[1] < minLat) minLat = pt[1];
      if (pt[1] > maxLat) maxLat = pt[1];
      if (pt[0] < minLng) minLng = pt[0];
      if (pt[0] > maxLng) maxLng = pt[0];
    }
    final dLat = (maxLat - minLat) * 111320;
    final dLng =
        (maxLng - minLng) * 111320 * math.cos(minLat * math.pi / 180);
    return math.max(dLat, dLng);
  }

  List<List<double>> _simplifyPolygon(List<List<double>> poly,
      {int max = 28}) {
    if (poly.length <= max) return poly;
    final step = poly.length / max;
    return [for (int i = 0; i < max; i++) poly[(i * step).floor()]];
  }

  List<List<double>> _makeCirclePolygon(double lat, double lng,
      double radiusMeters, {int points = 24}) {
    const mPerDegLat = 111320.0;
    final mPerDegLng = 111320.0 * math.cos(lat * math.pi / 180);
    return [
      for (int i = 0; i <= points; i++)
        [
          lng + (radiusMeters * math.cos(2 * math.pi * i / points)) / mPerDegLng,
          lat + (radiusMeters * math.sin(2 * math.pi * i / points)) / mPerDegLat,
        ],
    ];
  }

  // ── Polygon save/load ─────────────────────────────────────
  Future<void> _savePolygons() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _polygonsKey,
      jsonEncode(_buildingPolygons.map(
        (id, polys) => MapEntry(id, jsonEncode(polys)),
      )),
    );
  }

  Future<void> _loadPolygons() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_polygonsKey);
      if (raw == null) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in map.entries) {
        final polys = (jsonDecode(entry.value as String) as List)
            .map((poly) => (poly as List)
                .map((c) =>
                    (c as List).map((v) => (v as num).toDouble()).toList())
                .toList())
            .where((poly) => poly.length >= 3)
            .toList();
        if (polys.isNotEmpty) _buildingPolygons[entry.key] = polys;
      }
    } catch (_) {}
  }

  // ── Pin save/load ─────────────────────────────────────────
  Future<void> _savePins() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _prefsKey, _pins.map((p) => jsonEncode(p.toJson())).toList());
  }

  Future<void> _loadPins() async {
    final prefs = await SharedPreferences.getInstance();
    await _loadPolygons();
    final list = prefs.getStringList(_prefsKey) ?? [];
    for (final raw in list) {
      try {
        final pin = CapsulePin.fromJson(
            jsonDecode(raw) as Map<String, dynamic>);
        if (pin.photoPath == null || File(pin.photoPath!).existsSync()) {
          _pins.add(pin);
          await _addMarkerToMap(pin);
        }
      } catch (_) {}
    }
  }

  Future<void> _addMarkerToMap(CapsulePin pin) async {
    if (_mapboxMap == null || _annotationManager == null) return;
    final Uint8List markerImg;
    if (pin.photo != null && pin.photo!.existsSync()) {
      markerImg = await _makePhotoMarker(pin.photo!);
    } else {
      markerImg = await _makeDotImage(color: const Color(0xFF7B5EA7));
    }
    final annotation = await _annotationManager!.create(
      PointAnnotationOptions(
        geometry: Point(coordinates: Position(pin.lng, pin.lat)),
        image: markerImg,
        iconSize: 0.8,
      ),
    );
    _annotationMap[pin.id] = annotation;
    _annotationIdToPinId[annotation.id] = pin.id;
  }

  // ── Map init ──────────────────────────────────────────────
  Future<void> _onMapCreated(MapboxMap mapboxMap) async {
    _mapboxMap = mapboxMap;
    _annotationManager =
        await _mapboxMap!.annotations.createPointAnnotationManager();
    // ignore: deprecated_member_use
    _annotationManager!.addOnPointAnnotationClickListener(this);
    await _moveToMyLocation();
    _startTracking();
    await _onStyleLoaded();
    await _loadPins();
    _mapboxMap!.setOnCameraChangeListener((_) => _scheduleFogUpdate());
  }

  Future<void> _onStyleLoaded() async {
    await _refineBaseStyle();
    await _add3DBuildings();
  }

  Future<void> _refineBaseStyle() async {
    if (_mapboxMap == null) return;
    for (final id in [
      'building', 'building-top', 'building-outline',
      'building-3d', 'building-fill', 'building-extrusion',
    ]) {
      try {
        await _mapboxMap!.style.setStyleLayerProperty(id, 'visibility', 'none');
      } catch (_) {}
    }
  }

  Future<void> _add3DBuildings() async {
    if (_mapboxMap == null) return;
    try {
      await _mapboxMap!.style.addLayer(
        FillExtrusionLayer(
          id: 'building-3d-dark',
          sourceId: 'composite',
          sourceLayer: 'building',
          fillExtrusionColor: 0xFF2A2520.toSigned(32),
          fillExtrusionHeightExpression: [
            'interpolate', ['linear'], ['zoom'],
            14, 0,
            14.5, ['*', ['number', ['get', 'height'], 8], 2],
          ],
          fillExtrusionBaseExpression: [
            '*', ['number', ['get', 'min_height'], 0], 2,
          ],
          fillExtrusionOpacityExpression: [
            'interpolate', ['linear'], ['zoom'],
            14, 0.0,
            15, 0.9,
          ],
        ),
      );
    } catch (e) {
      debugPrint('3D 건물 오류: $e');
    }
  }

  Future<void> _moveToMyLocation() async {
    try {
      geo.LocationPermission perm = await geo.Geolocator.checkPermission();
      if (perm == geo.LocationPermission.denied) {
        perm = await geo.Geolocator.requestPermission();
      }
      final pos = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
            accuracy: geo.LocationAccuracy.high),
      );
      await _mapboxMap?.flyTo(
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
    if (_mapboxMap == null || _annotationManager == null) return;
    final dotImg = await _makeDotImage(color: const Color(0xFF4A90E2));
    if (_myLocAnnotation != null) {
      _myLocAnnotation!.geometry = Point(coordinates: Position(lng, lat));
      _myLocAnnotation!.image = dotImg;
      await _annotationManager!.update(_myLocAnnotation!);
    } else {
      _myLocAnnotation = await _annotationManager!.create(
        PointAnnotationOptions(
          geometry: Point(coordinates: Position(lng, lat)),
          image: dotImg,
          iconSize: 1.0,
        ),
      );
    }
  }

  Future<Uint8List> _makeDotImage({required Color color}) async {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec, const Rect.fromLTWH(0, 0, 40, 40));
    c.drawCircle(const Offset(20, 20), 18, Paint()..color = Colors.white);
    c.drawCircle(const Offset(20, 20), 13, Paint()..color = color);
    final img = await rec.endRecording().toImage(40, 40);
    final d = await img.toByteData(format: ui.ImageByteFormat.png);
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

  Future<(geo.Position?, String)> _extractGpsFromBytes(Uint8List bytes) async {
    try {
      final data = await readExifFromBytes(bytes);
      if (data.isEmpty) return (null, 'EXIF 데이터가 없어요.');
      if (!data.containsKey('GPS GPSLatitude') ||
          !data.containsKey('GPS GPSLongitude')) {
        return (null, 'GPS 정보가 없어요. 카메라 설정에서 위치 태그를 켜주세요.');
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
          latitude: lat, longitude: lng,
          timestamp: DateTime.now(),
          accuracy: 0, altitude: 0, altitudeAccuracy: 0,
          heading: 0, headingAccuracy: 0, speed: 0, speedAccuracy: 0,
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
    final exifData = await readExifFromBytes(bytes);
    int orientation = 1;
    final orientTag = exifData['Image Orientation'];
    if (orientTag != null) {
      orientation = int.tryParse(orientTag.printable.split(' ').first) ?? 1;
    }

    final image = await decodeImageFromList(bytes);
    const double sz = 140, pad = 10;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec, Rect.fromLTWH(0, 0, sz, sz + 20));

    final tail = Path()
      ..moveTo(sz / 2 - 10, sz - 4)
      ..lineTo(sz / 2, sz + 20)
      ..lineTo(sz / 2 + 10, sz - 4)
      ..close();
    c.drawPath(tail, Paint()..color = const Color(0xFF7B5EA7));
    c.drawCircle(Offset(sz / 2, sz / 2), sz / 2 - 2,
        Paint()..color = const Color(0xFF7B5EA7));
    c.clipPath(Path()
      ..addOval(Rect.fromCircle(
          center: Offset(sz / 2, sz / 2), radius: sz / 2 - pad)));

    c.save();
    c.translate(sz / 2, sz / 2);
    if (orientation == 3) { c.rotate(math.pi); }
    else if (orientation == 6) { c.rotate(math.pi / 2); }
    else if (orientation == 8) { c.rotate(-math.pi / 2); }
    c.translate(-sz / 2, -sz / 2);

    final sw = image.width.toDouble(), sh = image.height.toDouble();
    final ms = math.min(sw, sh);
    c.drawImageRect(
      image,
      Rect.fromCenter(center: Offset(sw / 2, sh / 2), width: ms, height: ms),
      Rect.fromLTWH(pad, pad, sz - pad * 2, sz - pad * 2),
      Paint(),
    );
    c.restore();

    final out = await rec.endRecording().toImage(sz.toInt(), (sz + 20).toInt());
    final d = await out.toByteData(format: ui.ImageByteFormat.png);
    return d!.buffer.asUint8List();
  }

  // ── Add photo pin ─────────────────────────────────────────
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
              accuracy: geo.LocationAccuracy.high),
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

      await _mapboxMap?.flyTo(
        CameraOptions(
          center: Point(coordinates: Position(gpsPos.longitude, gpsPos.latitude)),
          zoom: 18.5,
          pitch: 65.0,
          bearing: 0.0,
        ),
        MapAnimationOptions(duration: 1800),
      );

      final polygons =
          await _queryStreetBuildings(gpsPos.latitude, gpsPos.longitude);
      _buildingPolygons[pin.id] = polygons;
      await _savePolygons();
      _scheduleFogUpdate();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('오류: $e')));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _deletePin(CapsulePin pin) async {
    final annotation = _annotationMap[pin.id];
    if (annotation != null && _annotationManager != null) {
      await _annotationManager!.delete(annotation);
      _annotationIdToPinId.remove(annotation.id);
      _annotationMap.remove(pin.id);
    }
    _pins.removeWhere((p) => p.id == pin.id);
    _buildingPolygons.remove(pin.id);
    await _savePins();
    await _savePolygons();
    _scheduleFogUpdate();
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
                child: Image.file(pin.photo!,
                    height: 200, width: double.infinity, fit: BoxFit.cover),
              ),
            const SizedBox(height: 16),
            Text(
              pin.title,
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF2E2B2A)),
            ),
            const SizedBox(height: 8),
            Text(
              '📍 ${pin.lat.toStringAsFixed(5)}, ${pin.lng.toStringAsFixed(5)}',
              style: const TextStyle(color: Color(0xFF7A756D), fontSize: 13),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      _mapboxMap?.flyTo(
                        CameraOptions(
                          center: Point(coordinates: Position(pin.lng, pin.lat)),
                          zoom: 18.5,
                          pitch: 60.0,
                        ),
                        MapAnimationOptions(duration: 1000),
                      );
                    },
                    icon: const Icon(Icons.my_location, size: 18),
                    label: const Text('위치로 이동'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF7B5EA7),
                      side: const BorderSide(color: Color(0xFF7B5EA7)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const Text('캡슐 삭제'),
                          content: const Text('이 타임캡슐을 삭제할까요?\n안개도 다시 덮입니다.'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('취소'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('삭제',
                                  style: TextStyle(color: Colors.red)),
                            ),
                          ],
                        ),
                      );
                      if (confirm == true && mounted) {
                        Navigator.pop(context);
                        await _deletePin(pin);
                      }
                    },
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('삭제'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: const BorderSide(color: Colors.red),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    MapboxOptions.setAccessToken(
      const String.fromEnvironment('MAPBOX_TOKEN'),
    );
    return Scaffold(
      body: Stack(
        children: [
          MapWidget(
            key: const ValueKey('map'),
            styleUri: _styleUri,
            onMapCreated: _onMapCreated,
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: UnityWidget(
                onUnityCreated: _onUnityCreated,
                onUnityMessage: _onUnityMessage,
                onUnitySceneLoaded: _onUnitySceneLoaded,
                useAndroidViewSurface: true,
                fullscreen: false,
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
    return FloatingActionButton(
      heroTag: heroTag,
      backgroundColor: backgroundColor,
      onPressed: onPressed,
      child: Icon(icon, color: iconColor),
    );
  }
}
