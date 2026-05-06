import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:image_picker/image_picker.dart' as img_picker;
import 'package:exif/exif.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
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

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => MapScreenState();
}

class MapScreenState extends State<MapScreen>
    with AutomaticKeepAliveClientMixin {
  static const String _prefsKey = 'capsule_pins';
  static const String _polygonsKey = 'capsule_polygons_v11';

  // OpenFreeMap positron - 깔끔한 밝은 배경
  static const String _styleUrl =
      'https://tiles.openfreemap.org/styles/positron';

  MapLibreMapController? _map;
  Symbol? _myLocSymbol;
  final Map<String, Symbol> _symbolMap = {};

  final List<CapsulePin> _pins = [];
  final Map<String, List<List<List<double>>>> _buildingPolygons = {};
  final img_picker.ImagePicker _picker = img_picker.ImagePicker();
  StreamSubscription<geo.Position>? _posSub;

  List<List<Offset>> _fogPolygons = [];
  List<Offset> _fogCenters = [];
  bool _isLoading = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _posSub?.cancel();
    _map?.onSymbolTapped.remove(_onSymbolTapped);
    super.dispose();
  }

  // ── 구역 기반 건물 폴리곤 쿼리 ──────────────────────────
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

    debugPrint('Overpass: 모든 단계 실패 → 원형 폴백');
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
      if (res.statusCode != 200) {
        debugPrint('Overpass[$tag] HTTP ${res.statusCode}');
        return [];
      }
      final elements =
          (jsonDecode(res.body) as Map)['elements'] as List? ?? [];
      debugPrint('Overpass[$tag] elements: ${elements.length}');

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
      debugPrint('Overpass[$tag] 폴리곤: ${polys.length}');
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
        () {
          final angle = 2 * math.pi * i / points;
          return [
            lng + (radiusMeters * math.cos(angle)) / mPerDegLng,
            lat + (radiusMeters * math.sin(angle)) / mPerDegLat,
          ];
        }(),
    ];
  }

  // ── 폴리곤 저장/불러오기 ─────────────────────────────────
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

  // ── 안개 화면 좌표 업데이트 ──────────────────────────────
  Future<void> _updateFogPositions() async {
    if (_map == null || !mounted) return;
    final polys = <List<Offset>>[];
    final centers = <Offset>[];
    for (final pin in _pins) {
      final geoPolys = _buildingPolygons[pin.id];
      if (geoPolys == null || geoPolys.isEmpty) continue;
      try {
        for (final geoPoly in geoPolys) {
          final screenPoly = <Offset>[];
          for (final pt in geoPoly) {
            final sc = await _map!
                .toScreenLocation(LatLng(pt[1], pt[0]));
            screenPoly.add(Offset(sc.x.toDouble(), sc.y.toDouble()));
          }
          if (screenPoly.length >= 3) polys.add(screenPoly);
        }
        final cc =
            await _map!.toScreenLocation(LatLng(pin.lat, pin.lng));
        centers.add(Offset(cc.x.toDouble(), cc.y.toDouble()));
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _fogPolygons = polys;
        _fogCenters = centers;
      });
    }
  }

  // ── 저장/불러오기 ─────────────────────────────────────────
  Future<void> _savePins() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _pins.map((p) => jsonEncode(p.toJson())).toList();
    await prefs.setStringList(_prefsKey, list);
  }

  Future<void> _loadPins() async {
    final prefs = await SharedPreferences.getInstance();
    await _loadPolygons();
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
    if (_map == null) return;
    Uint8List markerImg;
    if (pin.photo != null && pin.photo!.existsSync()) {
      markerImg = await _makePhotoMarker(pin.photo!);
    } else {
      markerImg = await _makeDotImage(color: const Color(0xFF7B5EA7));
    }
    final imageId = 'marker-${pin.id}';
    await _map!.addImage(imageId, markerImg);
    final symbol = await _map!.addSymbol(SymbolOptions(
      geometry: LatLng(pin.lat, pin.lng),
      iconImage: imageId,
      iconSize: 0.8,
    ));
    _symbolMap[pin.id] = symbol;
  }

  void _onSymbolTapped(Symbol symbol) {
    final pinId = _symbolMap.entries
        .firstWhere(
          (e) => e.value.id == symbol.id,
          orElse: () => MapEntry('', symbol),
        )
        .key;
    if (pinId.isEmpty) return;
    final p = _pins.firstWhere(
      (p) => p.id == pinId,
      orElse: () => CapsulePin(id: '', lat: 0, lng: 0, title: ''),
    );
    if (p.id.isNotEmpty) _showPinSheet(p);
  }

  // ── 지도 초기화 ───────────────────────────────────────────
  Future<void> _onMapCreated(MapLibreMapController map) async {
    _map = map;
    map.onSymbolTapped.add(_onSymbolTapped);
    await _moveToMyLocation();
    _startTracking();
    await _loadPins();
  }

  Future<void> _onStyleLoaded() async {
    await _refineBaseStyle();
    await _add3DBuildings();
    await _updateFogPositions();
  }

  Future<void> _refineBaseStyle() async {
    if (_map == null) return;
    // 기존 2D 건물 레이어 숨기기 (3D로 대체)
    for (final id in ['building', 'building-top', 'building-outline',
                       'building-3d', 'building-fill']) {
      try {
        await _map!.setLayerProperties(
            id, const FillLayerProperties(fillOpacity: 0));
      } catch (_) {}
      try {
        await _map!.setLayerProperties(
            id, const LineLayerProperties(lineOpacity: 0));
      } catch (_) {}
    }
    // 물 색상 - 부드러운 파란색
    for (final id in ['water', 'water-polygon']) {
      try {
        await _map!.setLayerProperties(
            id, const FillLayerProperties(fillColor: '#A8C8DC'));
      } catch (_) {}
    }
  }

  Future<void> _add3DBuildings() async {
    if (_map == null) return;
    try {
      await _map!.addLayer(
        'openmaptiles',
        'building',
        FillExtrusionLayerProperties(
          // 줌 14부터 서서히 올라옴
          fillExtrusionHeight: [
            'interpolate', ['linear'], ['zoom'],
            14, 0,
            14.5, ['*', ['number', ['get', 'render_height'], 8], 2]
          ],
          fillExtrusionBase: [
            '*', ['number', ['get', 'render_min_height'], 0], 2
          ],
          // 건물 용도별 색상 구분
          fillExtrusionColor: [
            'match', ['get', 'class'],
            'residential',  '#5C4A4A',
            'apartments',   '#5C4A4A',
            'commercial',   '#3D4A5C',
            'retail',       '#4A5060',
            'industrial',   '#4A4A3C',
            'public',       '#4A3D58',
            'office',       '#3A4A5C',
            '#504040'  // 기본
          ],
          fillExtrusionOpacity: [
            'interpolate', ['linear'], ['zoom'],
            14, 0.0,
            15, 0.85
          ],
        ),
      );
    } catch (e) {
      debugPrint('3D 건물 레이어 오류: $e');
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
          accuracy: geo.LocationAccuracy.high,
        ),
      );
      await _map?.animateCamera(
        CameraUpdate.newCameraPosition(CameraPosition(
          target: LatLng(pos.latitude, pos.longitude),
          zoom: 16.0,
          tilt: 45.0,
        )),
        duration: const Duration(milliseconds: 1000),
      );
      await _updateMyDot(pos.latitude, pos.longitude);
    } catch (e) {
      debugPrint('위치 오류: $e');
    }
  }

  Future<void> _updateMyDot(double lat, double lng) async {
    if (_map == null) return;
    final dotImg = await _makeDotImage(color: const Color(0xFF4A90E2));
    const imageId = 'my-location-dot';
    await _map!.addImage(imageId, dotImg);
    if (_myLocSymbol != null) {
      await _map!.updateSymbol(
        _myLocSymbol!,
        SymbolOptions(geometry: LatLng(lat, lng)),
      );
    } else {
      _myLocSymbol = await _map!.addSymbol(SymbolOptions(
        geometry: LatLng(lat, lng),
        iconImage: imageId,
        iconSize: 1.0,
      ));
    }
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

      await _map?.animateCamera(
        CameraUpdate.newCameraPosition(CameraPosition(
          target: LatLng(gpsPos.latitude, gpsPos.longitude),
          zoom: 18.5,
          tilt: 65.0,
          bearing: 0.0,
        )),
        duration: const Duration(milliseconds: 1800),
      );

      final polygons =
          await _queryStreetBuildings(gpsPos.latitude, gpsPos.longitude);
      _buildingPolygons[pin.id] = polygons;
      await _savePolygons();
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
          MapLibreMap(
            styleString: _styleUrl,
            initialCameraPosition: const CameraPosition(
              target: LatLng(36.4800, 127.2890),
              zoom: 6.0,
              tilt: 45.0,
            ),
            onMapCreated: _onMapCreated,
            onStyleLoadedCallback: _onStyleLoaded,
            onCameraIdle: _updateFogPositions,
            myLocationEnabled: false,
            trackCameraPosition: true,
          ),
          // 안개 오버레이
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: GradientFogPainter(
                  polygons: _fogPolygons,
                  centers: _fogCenters,
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
    return FloatingActionButton(
      heroTag: heroTag,
      backgroundColor: backgroundColor,
      onPressed: onPressed,
      child: Icon(icon, color: iconColor),
    );
  }
}
