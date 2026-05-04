import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:image_picker/image_picker.dart' as img_picker;
import 'package:exif/exif.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
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
  static const String _polygonsKey = 'capsule_polygons';

  MapboxMap? _map;
  PointAnnotationManager? _pinManager;
  PointAnnotationManager? _myLocManager;
  PointAnnotation? _myLocMarker;

  final List<CapsulePin> _pins = [];
  final Map<String, String> _markerMap = {};
  final Map<String, List<List<double>>> _buildingPolygons = {};
  final img_picker.ImagePicker _picker = img_picker.ImagePicker();
  StreamSubscription<geo.Position>? _posSub;

  bool _isLoading = false;
  bool _tapListenerRegistered = false;

  static const _overlaySourceId = 'night-overlay-source';
  static const _overlayLayerId = 'night-overlay-layer';

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

  // ── Mapbox 야간 오버레이 ───────────────────────────────────
  Future<void> _initOverlayLayer() async {
    if (_map == null) return;
    try {
      final exists = await _map!.style.styleLayerExists(_overlayLayerId);
      if (exists) {
        await _updateOverlay();
        return;
      }
      await _map!.style.addSource(
        GeoJsonSource(
          id: _overlaySourceId,
          data: jsonEncode(_buildOverlayGeoJson()),
        ),
      );
      await _map!.style.addLayer(
        FillLayer(id: _overlayLayerId, sourceId: _overlaySourceId),
      );
      await _map!.style.setStyleLayerProperty(
        _overlayLayerId,
        'fill-color',
        '#05101F',
      );
      await _map!.style.setStyleLayerProperty(
        _overlayLayerId,
        'fill-opacity',
        0.85,
      );
    } catch (e) {
      debugPrint('오버레이 초기화 오류: $e');
    }
  }

  Future<void> _updateOverlay() async {
    if (_map == null) return;
    try {
      await _map!.style.setStyleSourceProperty(
        _overlaySourceId,
        'data',
        jsonEncode(_buildOverlayGeoJson()),
      );
    } catch (e) {
      debugPrint('오버레이 업데이트 오류: $e');
    }
  }

  /// 겹치는 폴리곤들을 Convex Hull로 병합하여 GeoJSON 생성
  /// → 겹친 영역이 어두워지는 버그 수정
  Map<String, dynamic> _buildOverlayGeoJson() {
    final rings = <List<List<double>>>[
      // 외부 링: CCW (전 세계)
      [
        [-180.0, -85.0],
        [180.0, -85.0],
        [180.0, 85.0],
        [-180.0, 85.0],
        [-180.0, -85.0],
      ],
    ];
    // 겹치는 폴리곤 병합 후 hole로 추가
    for (final polygon in _getMergedPolygons()) {
      if (polygon.length >= 3) {
        rings.add(_toClockwise(polygon));
      }
    }
    return {
      'type': 'Feature',
      'geometry': {'type': 'Polygon', 'coordinates': rings},
    };
  }

  /// 겹치는 폴리곤들을 그룹화하여 Convex Hull로 병합
  /// 겹치지 않는 폴리곤은 그대로 반환
  List<List<List<double>>> _getMergedPolygons() {
    final polygons = _buildingPolygons.values.toList();
    if (polygons.isEmpty) return [];
    if (polygons.length == 1) return polygons;

    // Union-Find로 겹치는 그룹 탐색
    final parent = List.generate(polygons.length, (i) => i);

    int find(int x) {
      while (parent[x] != x) {
        parent[x] = parent[parent[x]];
        x = parent[x];
      }
      return x;
    }

    void union(int a, int b) {
      parent[find(a)] = find(b);
    }

    for (int i = 0; i < polygons.length; i++) {
      for (int j = i + 1; j < polygons.length; j++) {
        if (_polygonsOverlap(polygons[i], polygons[j])) {
          union(i, j);
        }
      }
    }

    // 그룹별 점 모아서 Convex Hull 계산
    final groups = <int, List<List<double>>>{};
    for (int i = 0; i < polygons.length; i++) {
      groups.putIfAbsent(find(i), () => []).addAll(polygons[i]);
    }

    return groups.values.map(_convexHull).toList();
  }

  /// 두 폴리곤이 겹치는지 확인 (바운딩 박스 + 점-내부 테스트)
  bool _polygonsOverlap(List<List<double>> a, List<List<double>> b) {
    final bboxA = _bbox(a);
    final bboxB = _bbox(b);
    // 바운딩 박스가 겹치지 않으면 빠른 탈출
    if (bboxA[2] < bboxB[0] || bboxB[2] < bboxA[0] ||
        bboxA[3] < bboxB[1] || bboxB[3] < bboxA[1]) return false;
    // 점-in-폴리곤 테스트
    for (final pt in a) {
      if (_pointInPolygon(pt, b)) return true;
    }
    for (final pt in b) {
      if (_pointInPolygon(pt, a)) return true;
    }
    return false;
  }

  List<double> _bbox(List<List<double>> poly) {
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final pt in poly) {
      if (pt[0] < minX) minX = pt[0];
      if (pt[1] < minY) minY = pt[1];
      if (pt[0] > maxX) maxX = pt[0];
      if (pt[1] > maxY) maxY = pt[1];
    }
    return [minX, minY, maxX, maxY];
  }

  bool _pointInPolygon(List<double> point, List<List<double>> polygon) {
    bool inside = false;
    final x = point[0], y = point[1];
    for (int i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final xi = polygon[i][0], yi = polygon[i][1];
      final xj = polygon[j][0], yj = polygon[j][1];
      if ((yi > y) != (yj > y) &&
          x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
        inside = !inside;
      }
    }
    return inside;
  }

  /// Graham Scan으로 Convex Hull 계산 (GeoJSON 링 형식으로 반환)
  List<List<double>> _convexHull(List<List<double>> pts) {
    if (pts.length < 3) {
      final result = List<List<double>>.from(pts);
      if (result.isNotEmpty) result.add(result.first);
      return result;
    }

    final points = List<List<double>>.from(pts);

    // 가장 아래쪽(y 최소, 동일하면 x 최소) 점 찾기
    int startIdx = 0;
    for (int i = 1; i < points.length; i++) {
      if (points[i][1] < points[startIdx][1] ||
          (points[i][1] == points[startIdx][1] &&
              points[i][0] < points[startIdx][0])) {
        startIdx = i;
      }
    }
    final start = points.removeAt(startIdx);

    // 극각 기준 정렬
    points.sort((a, b) {
      final angleA = math.atan2(a[1] - start[1], a[0] - start[0]);
      final angleB = math.atan2(b[1] - start[1], b[0] - start[0]);
      final diff = angleA - angleB;
      if (diff.abs() > 1e-10) return diff < 0 ? -1 : 1;
      final dA = (a[0] - start[0]) * (a[0] - start[0]) +
          (a[1] - start[1]) * (a[1] - start[1]);
      final dB = (b[0] - start[0]) * (b[0] - start[0]) +
          (b[1] - start[1]) * (b[1] - start[1]);
      return dA.compareTo(dB);
    });

    final hull = <List<double>>[start];
    for (final p in points) {
      while (hull.length >= 2 &&
          _cross(hull[hull.length - 2], hull.last, p) <= 0) {
        hull.removeLast();
      }
      hull.add(p);
    }
    hull.add(hull.first); // 링 닫기
    return hull;
  }

  double _cross(List<double> o, List<double> a, List<double> b) {
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
  }

  /// 링을 시계방향(CW)으로 보장 (GeoJSON hole 요건)
  List<List<double>> _toClockwise(List<List<double>> ring) {
    double area = 0;
    for (int i = 0; i < ring.length - 1; i++) {
      area += ring[i][0] * ring[i + 1][1] - ring[i + 1][0] * ring[i][1];
    }
    return area > 0 ? ring.reversed.toList() : ring;
  }

  // ── OSM Overpass API ─────────────────────────────────────
  List<List<double>>? _extractPolygon(Map<String, dynamic> body) {
    final elements = body['elements'] as List?;
    if (elements == null || elements.isEmpty) return null;

    List<List<double>>? parseGeom(List geom) {
      if (geom.length < 3) return null;
      return geom.map((node) {
        final n = node as Map;
        return [(n['lon'] as num).toDouble(), (n['lat'] as num).toDouble()];
      }).toList();
    }

    for (final el in elements) {
      final map = el as Map;
      final geom = map['geometry'] as List?;
      if (geom != null) {
        final poly = parseGeom(geom);
        if (poly != null) return poly;
      }
      final members = map['members'] as List?;
      if (members != null) {
        for (final member in members) {
          final m = member as Map;
          if (m['role'] == 'outer') {
            final mGeom = m['geometry'] as List?;
            if (mGeom != null) {
              final poly = parseGeom(mGeom);
              if (poly != null) return poly;
            }
          }
        }
      }
    }
    return null;
  }

  Future<void> _queryBuildingForPin(CapsulePin pin) async {
    final lat = pin.lat, lng = pin.lng;

    Future<Map<String, dynamic>?> overpassGet(String q) async {
      final url = Uri.parse(
        'https://overpass-api.de/api/interpreter?data=${Uri.encodeComponent(q)}',
      );
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          final res =
              await http.get(url).timeout(const Duration(seconds: 15));
          if (res.statusCode == 200) {
            return jsonDecode(res.body) as Map<String, dynamic>;
          }
          if (res.statusCode == 429) {
            await Future.delayed(Duration(seconds: attempt * 5));
          } else {
            break;
          }
        } catch (e) {
          debugPrint('Overpass 오류: $e');
          break;
        }
      }
      return null;
    }

    try {
      // 1단계: is_in으로 관광지/공원/대학/단지 경계
      final areaQ =
          '[out:json];is_in($lat,$lng)->.a;('
          'way["tourism"](pivot.a);'
          'way["leisure"="park"](pivot.a);'
          'way["leisure"="nature_reserve"](pivot.a);'
          'way["historic"](pivot.a);'
          'way["amenity"="university"](pivot.a);'
          'way["landuse"="residential"](pivot.a);'
          'way["landuse"="apartments"](pivot.a);'
          'relation["tourism"](pivot.a);'
          'relation["leisure"="park"](pivot.a);'
          ');out geom;';
      final areaBody = await overpassGet(areaQ);
      if (areaBody != null) {
        final polygon = _extractPolygon(areaBody);
        if (polygon != null) {
          _buildingPolygons[pin.id] = polygon;
          return;
        }
      }

      // 2단계: 반경 50m 내 개별 건물
      final buildingQ =
          '[out:json];way["building"](around:50,$lat,$lng);out geom;';
      final buildingBody = await overpassGet(buildingQ);
      if (buildingBody != null) {
        final polygon = _extractPolygon(buildingBody);
        if (polygon != null) {
          _buildingPolygons[pin.id] = polygon;
          return;
        }
      }

      // 3단계: 원형 fallback (반경 80m)
      _buildingPolygons[pin.id] = _makeCirclePolygon(lat, lng, 80);
    } catch (e) {
      debugPrint('건물 쿼리 오류: $e');
      _buildingPolygons[pin.id] = _makeCirclePolygon(lat, lng, 80);
    }
  }

  List<List<double>> _makeCirclePolygon(
    double lat,
    double lng,
    double radiusMeters, {
    int points = 36,
  }) {
    const mPerDegLat = 111320.0;
    final mPerDegLng = 111320.0 * math.cos(lat * math.pi / 180);
    final ring = <List<double>>[];
    for (int i = 0; i <= points; i++) {
      final angle = 2 * math.pi * i / points;
      final dlat = (radiusMeters * math.sin(angle)) / mPerDegLat;
      final dlng = (radiusMeters * math.cos(angle)) / mPerDegLng;
      ring.add([lng + dlng, lat + dlat]);
    }
    return ring;
  }

  // ── 저장/불러오기 ─────────────────────────────────────────
  Future<void> _savePins() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _pins.map((p) => jsonEncode(p.toJson())).toList();
    await prefs.setStringList(_prefsKey, list);
  }

  Future<void> _savePolygons() async {
    final prefs = await SharedPreferences.getInstance();
    final map = _buildingPolygons.map(
      (id, coords) => MapEntry(id, jsonEncode(coords)),
    );
    await prefs.setString(_polygonsKey, jsonEncode(map));
  }

  Future<void> _loadPolygons() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_polygonsKey);
      if (raw == null) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in map.entries) {
        final coords = (jsonDecode(entry.value as String) as List)
            .map(
              (c) =>
                  (c as List).map((v) => (v as num).toDouble()).toList(),
            )
            .toList();
        _buildingPolygons[entry.key] = coords;
      }
    } catch (_) {}
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
          if (!_buildingPolygons.containsKey(pin.id)) {
            await Future.delayed(const Duration(seconds: 2));
            await _queryBuildingForPin(pin);
            await _savePolygons();
          }
        }
      } catch (_) {}
    }
    await _updateOverlay();
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

  // ── 3D 지형 설정 ─────────────────────────────────────────
  Future<void> _initTerrain() async {
    if (_map == null) return;
    try {
      final demExists = await _map!.style.styleSourceExists('mapbox-dem');
      if (!demExists) {
        await _map!.style.addSource(
          RasterDemSource(
            id: 'mapbox-dem',
            url: 'mapbox://mapbox.mapbox-terrain-dem-v1',
            tileSize: 512,
            maxzoom: 14.0,
          ),
        );
      }
      // 지형 고도 활성화 (1.5배 과장으로 한국 산악 지형 강조)
      await _map!.style.setStyleTerrain(
        jsonEncode({'source': 'mapbox-dem', 'exaggeration': 1.5}),
      );
      // 대기권(하늘) 레이어 추가 — 입체감 강화
      final skyExists = await _map!.style.styleLayerExists('sky-3d');
      if (!skyExists) {
        await _map!.style.addLayer(
          SkyLayer(
            id: 'sky-3d',
            skyType: SkyType.ATMOSPHERE,
            skyAtmosphereSun: [0.0, 90.0],
            skyAtmosphereSunIntensity: 15.0,
          ),
        );
      }
    } catch (e) {
      debugPrint('지형 초기화 오류: $e');
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
        pitchEnabled: true,
        doubleTapToZoomInEnabled: true,
        doubleTouchToZoomOutEnabled: true,
        quickZoomEnabled: true,
      ),
    );
    await _initOverlayLayer();
    await _moveToMyLocation();
    _startTracking();
    await _loadPins();
  }

  Future<void> _onStyleLoaded(StyleLoadedEventData _) async {
    await _initOverlayLayer();
    await _updateOverlay();
    await _initTerrain();
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
          zoom: 14.0,
          pitch: 50.0,
          bearing: 0.0,
        ),
        MapAnimationOptions(duration: 1200),
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

      await Future.delayed(const Duration(milliseconds: 1000));
      await _queryBuildingForPin(pin);
      await _savePolygons();
      await _updateOverlay();
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
            styleUri: MapboxStyles.STANDARD,
            cameraOptions: CameraOptions(
              center: Point(coordinates: Position(127.9785, 37.5665)),
              zoom: 7.0,
              pitch: 45.0,
              bearing: 0.0,
            ),
            onMapCreated: _onMapCreated,
            onStyleLoadedListener: _onStyleLoaded,
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
