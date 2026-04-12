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

  // ── Mapbox 네이티브 오버레이 (지리좌표 → 화면좌표 변환 불필요) ──
  /// 전 세계를 덮는 어두운 FillLayer + 핀 폴리곤을 구멍으로 뚫음
  Future<void> _initOverlayLayer() async {
    if (_map == null) return;
    try {
      // 이미 존재하면 데이터만 업데이트
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
      debugPrint('오버레이 레이어 초기화 오류: $e');
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

  /// 전 세계 외부링(CCW) + 핀 폴리곤을 구멍(CW)으로 하는 GeoJSON 생성
  Map<String, dynamic> _buildOverlayGeoJson() {
    final rings = <List<List<double>>>[
      // 외부 링: CCW (반시계방향) → SW→SE→NE→NW→SW 순서
      // Shoelace 검증: area > 0 → 반시계방향 ✓
      [
        [-180.0, -85.0],
        [180.0, -85.0],
        [180.0, 85.0],
        [-180.0, 85.0],
        [-180.0, -85.0],
      ],
    ];
    for (final polygon in _buildingPolygons.values) {
      if (polygon.length >= 3) {
        // 홀 링은 CW(시계방향)이어야 겹쳐도 밝은 영역 유지
        rings.add(_toClockwise(polygon));
      }
    }
    return {
      'type': 'Feature',
      'geometry': {'type': 'Polygon', 'coordinates': rings},
    };
  }

  /// 링을 시계방향(CW)으로 보장 (GeoJSON 홀 링 요건)
  List<List<double>> _toClockwise(List<List<double>> ring) {
    double area = 0;
    for (int i = 0; i < ring.length - 1; i++) {
      area += ring[i][0] * ring[i + 1][1] - ring[i + 1][0] * ring[i][1];
    }
    // area > 0 → CCW → 뒤집어서 CW로
    return area > 0 ? ring.reversed.toList() : ring;
  }

  /// 좌표를 포함하는 OSM 폴리곤 geometry 추출 헬퍼
  /// way → geometry 직접 파싱 / relation → outer member way geometry 파싱
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

      // Way: 직접 geometry 필드
      final geom = map['geometry'] as List?;
      if (geom != null) {
        final poly = parseGeom(geom);
        if (poly != null) return poly;
      }

      // Relation: members 안의 outer role way geometry
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

  /// OSM Overpass API로 폴리곤 가져오기 (통합 쿼리)
  Future<void> _queryBuildingForPin(CapsulePin pin) async {
    final lat = pin.lat, lng = pin.lng;

    Future<Map<String, dynamic>?> overpassGet(String q) async {
      final url = Uri.parse(
        'https://overpass-api.de/api/interpreter?data=${Uri.encodeComponent(q)}',
      );
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          final res = await http.get(url).timeout(const Duration(seconds: 15));
          if (res.statusCode == 200)
            return jsonDecode(res.body) as Map<String, dynamic>;
          if (res.statusCode == 429) {
            final wait = attempt * 5;
            debugPrint('Overpass 429 → $wait초 대기 (시도 $attempt/3)');
            await Future.delayed(Duration(seconds: wait));
          } else {
            debugPrint('Overpass HTTP ${res.statusCode}');
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
          debugPrint('✅ 지역 폴리곤: ${polygon.length}개 꼭짓점');
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
          debugPrint('✅ 개별 건물: ${polygon.length}개 꼭짓점');
          return;
        }
      }

      // 3단계: 길바닥·야외·API 실패 모두 → 반경 80m 원형 폴리곤
      _buildingPolygons[pin.id] = _makeCirclePolygon(lat, lng, 80);
      debugPrint('⭕ 원형 fallback 적용 (반경 80m)');
    } catch (e) {
      debugPrint('건물 쿼리 오류: $e');
      _buildingPolygons[pin.id] = _makeCirclePolygon(lat, lng, 80);
    }
  }

  /// 위경도 기준 원형 GeoJSON 링 생성 (반경 미터)
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

  /// 폴리곤 캐시 저장 (재시작 시 Overpass 재쿼리 방지)
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
            .map((c) => (c as List).map((v) => (v as num).toDouble()).toList())
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
    // 모든 핀 로드 완료 후 한 번만 업데이트 (핀마다 호출하면 깜빡임)
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
    await _initOverlayLayer();
    await _moveToMyLocation();
    _startTracking();
    await _loadPins();
  }

  /// 스타일이 재로드될 때마다 오버레이 레이어 복구
  Future<void> _onStyleLoaded(StyleLoadedEventData _) async {
    await _initOverlayLayer();
    await _updateOverlay();
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
  // bytes를 직접 받아서 처리 (XFile.readAsBytes()로 content URI 원본 읽기)
  Future<(geo.Position?, String)> _extractGpsFromBytes(Uint8List bytes) async {
    try {
      final data = await readExifFromBytes(bytes);

      if (data.isEmpty) {
        return (null, 'EXIF 데이터가 없어요. 카메라로 직접 찍은 사진을 써보세요.');
      }
      if (!data.containsKey('GPS GPSLatitude') ||
          !data.containsKey('GPS GPSLongitude')) {
        return (null, 'GPS 정보가 없어요. 카메라 설정에서 "위치 태그"를 켜고 직접 찍은 사진을 써보세요.');
      }

      double? parseDMS(IfdTag tag) {
        final vals = tag.values.toList();
        if (vals.length < 3) return null;
        final deg = _toDouble(vals[0]);
        final min = _toDouble(vals[1]);
        final sec = _toDouble(vals[2]);
        debugPrint('  DMS: deg=$deg, min=$min, sec=$sec');
        if (deg == null || min == null || sec == null) return null;
        return deg + min / 60.0 + sec / 3600.0;
      }

      double? lat = parseDMS(data['GPS GPSLatitude']!);
      double? lng = parseDMS(data['GPS GPSLongitude']!);
      debugPrint('GPS 파싱 결과: lat=$lat, lng=$lng');

      if (lat == null || lng == null || (lat == 0.0 && lng == 0.0)) {
        return (null, 'GPS 값을 읽을 수 없어요. (lat=$lat, lng=$lng)');
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
      debugPrint('EXIF 오류: $e');
      return (null, 'EXIF 읽기 오류: $e');
    }
  }

  // Ratio / num / String 모두 처리
  double? _toDouble(dynamic val) {
    try {
      // exif Ratio 타입: numerator, denominator 프로퍼티
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
    final image = await decodeImageFromList(await photo.readAsBytes());
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
        Rect.fromCircle(center: Offset(sz / 2, sz / 2), radius: sz / 2 - pad),
      ),
    );
    final sw = image.width.toDouble(), sh = image.height.toDouble();
    final ms = math.min(sw, sh);
    c.drawImageRect(
      image,
      Rect.fromCenter(center: Offset(sw / 2, sh / 2), width: ms, height: ms),
      Rect.fromLTWH(pad, pad, sz - pad * 2, sz - pad * 2),
      Paint(),
    );
    final out = await rec.endRecording().toImage(sz.toInt(), (sz + 20).toInt());
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
    // Android 10+: ACCESS_MEDIA_LOCATION 런타임 권한 없으면 GPS가 0,0,0으로 치환됨
    if (!await Permission.accessMediaLocation.isGranted) {
      await Permission.accessMediaLocation.request();
    }
    // Android 13+: READ_MEDIA_IMAGES 런타임 권한
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
      // XFile.readAsBytes()로 content URI 원본에서 직접 읽어야 GPS EXIF 보존됨
      // File(picked.path).readAsBytes()는 캐시 복사본이라 GPS가 스트립될 수 있음
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

      // 핀 위치로 카메라 이동 (zoom 16 = 건물 명확히 보임)
      // 3D 건물이 보이는 입체 뷰로 이동
      await _map?.flyTo(
        CameraOptions(
          center: Point(
            coordinates: Position(gpsPos.longitude, gpsPos.latitude),
          ),
          zoom: 18.5,
          pitch: 65.0, // 기울기: 위에서 내려다보는 각도 (0=수직, 60=입체)
          bearing: 0.0, // 방위각: 0=북쪽 기준
        ),
        MapAnimationOptions(duration: 1800),
      );

      // 이동 완료 + 건물 타일 로드 대기 후 건물 쿼리
      await Future.delayed(const Duration(milliseconds: 1000));
      await _queryBuildingForPin(pin);
      await _savePolygons();
      await _updateOverlay(); // Mapbox 레이어 업데이트
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

  // ── 광화문 테스트 핀 ──────────────────────────────────────
  Future<void> _addGwanghwamunTestPin() async {
    setState(() => _isLoading = true);
    try {
      // 기존 광화문 테스트 핀이 있으면 제거
      _pins.removeWhere((p) => p.id == 'test_gwanghwamun');
      _buildingPolygons.remove('test_gwanghwamun');

      const double lat = 37.5759, lng = 126.9769; // 광화문광장
      final pin = CapsulePin(
        id: 'test_gwanghwamun',
        lat: lat,
        lng: lng,
        title: '광화문 테스트',
      );
      _pins.add(pin);
      await _addMarkerToMap(pin);

      // 3D 건물이 보이는 입체 뷰로 이동
      await _map?.flyTo(
        CameraOptions(
          center: Point(coordinates: Position(lng, lat)),
          zoom: 18.5,
          pitch: 65.0,
          bearing: 0.0,
        ),
        MapAnimationOptions(duration: 1800),
      );
      await Future.delayed(const Duration(milliseconds: 1000));
      await _queryBuildingForPin(pin);
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
          color: Colors.white,
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
                color: Colors.grey[300],
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
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '📍 ${pin.lat.toStringAsFixed(5)}, ${pin.lng.toStringAsFixed(5)}',
              style: TextStyle(color: Colors.grey[600], fontSize: 13),
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
              center: Point(coordinates: Position(127.2890, 36.4800)),
              zoom: 6.0,
            ),
            onMapCreated: _onMapCreated,
            onStyleLoadedListener: _onStyleLoaded,
          ),
          // 오버레이는 Mapbox FillLayer로 처리 (줌/패닝에 완전히 안정적)
          if (_isLoading)
            Container(
              color: Colors.black26,
              child: const Center(
                child: CircularProgressIndicator(color: Color(0xFF7B5EA7)),
              ),
            ),
          // 광화문 테스트 버튼 (임시)
          Positioned(
            bottom: 170,
            right: 16,
            child: FloatingActionButton(
              heroTag: 'test',
              backgroundColor: const Color(0xFFE8A838),
              onPressed: _addGwanghwamunTestPin,
              child: const Icon(Icons.flag, color: Colors.white),
            ),
          ),
          Positioned(
            bottom: 100,
            right: 16,
            child: FloatingActionButton(
              heroTag: 'photo',
              backgroundColor: const Color(0xFF7B5EA7),
              onPressed: addPhotoPin,
              child: const Icon(Icons.add_photo_alternate, color: Colors.white),
            ),
          ),
          Positioned(
            bottom: 30,
            right: 16,
            child: FloatingActionButton(
              heroTag: 'location',
              backgroundColor: Colors.white,
              onPressed: _moveToMyLocation,
              child: const Icon(Icons.my_location, color: Color(0xFF7B5EA7)),
            ),
          ),
        ],
      ),
    );
  }
}
