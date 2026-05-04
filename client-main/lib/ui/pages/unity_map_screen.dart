import 'package:flutter/material.dart';
import 'package:flutter_unity_widget/flutter_unity_widget.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:image_picker/image_picker.dart' as img_picker;
import 'package:exif/exif.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

// 기존 CapsulePin 모델 재사용
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
    'id': id, 'lat': lat, 'lng': lng, 'photoPath': photoPath, 'title': title,
  };

  factory CapsulePin.fromJson(Map<String, dynamic> j) => CapsulePin(
    id: j['id'] as String,
    lat: (j['lat'] as num).toDouble(),
    lng: (j['lng'] as num).toDouble(),
    photoPath: j['photoPath'] as String?,
    title: j['title'] as String,
  );
}

class UnityMapScreen extends StatefulWidget {
  const UnityMapScreen({super.key});

  @override
  State<UnityMapScreen> createState() => UnityMapScreenState();
}

class UnityMapScreenState extends State<UnityMapScreen>
    with AutomaticKeepAliveClientMixin {

  static const _prefsKey    = 'capsule_pins';
  static const _polygonsKey = 'capsule_polygons';

  UnityWidgetController? _unity;
  bool _unityReady = false;
  bool _isLoading  = false;

  final List<CapsulePin> _pins = [];
  final Map<String, List<List<double>>> _buildingPolygons = {};
  final img_picker.ImagePicker _picker = img_picker.ImagePicker();
  StreamSubscription<geo.Position>? _posSub;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _posSub?.cancel();
    _unity?.dispose();
    super.dispose();
  }

  // ── Unity 초기화 ─────────────────────────────────────────────

  void _onUnityCreated(UnityWidgetController controller) {
    _unity = controller;
  }

  void _onUnityMessage(String message) {
    try {
      final msg = jsonDecode(message) as Map<String, dynamic>;
      final type    = msg['type'] as String? ?? '';
      final payload = msg['payload'] as String? ?? '';

      switch (type) {
        case 'map_ready':
          _onMapReady();
        case 'pin_tapped':
          _onPinTapped(jsonDecode(payload) as Map<String, dynamic>);
      }
    } catch (e) {
      debugPrint('Unity 메시지 파싱 오류: $e');
    }
  }

  Future<void> _onMapReady() async {
    setState(() => _unityReady = true);
    await _moveToMyLocation();
    await _loadPins();
    _startTracking();
  }

  // ── Unity에 메시지 전송 ──────────────────────────────────────

  void _sendToUnity(String type, [String payload = '']) {
    if (!_unityReady || _unity == null) return;
    final msg = jsonEncode({'type': type, 'payload': payload});
    _unity!.postMessage('FlutterMessageManager', 'OnFlutterMessage', msg);
  }

  // ── 내 위치 이동 ─────────────────────────────────────────────

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
      _sendToUnity('move_camera', jsonEncode({
        'lat': pos.latitude, 'lng': pos.longitude,
        'zoom': 16.0, 'pitch': 50.0,
      }));
    } catch (e) {
      debugPrint('위치 오류: $e');
    }
  }

  void _startTracking() {
    _posSub = geo.Geolocator.getPositionStream(
      locationSettings: const geo.LocationSettings(
        accuracy: geo.LocationAccuracy.high,
        distanceFilter: 15,
      ),
    ).listen((p) {
      _sendToUnity('move_camera', jsonEncode({
        'lat': p.latitude, 'lng': p.longitude,
        'zoom': 16.0, 'pitch': 50.0,
      }));
    });
  }

  // ── 저장 / 불러오기 ──────────────────────────────────────────

  Future<void> _savePins() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _prefsKey, _pins.map((p) => jsonEncode(p.toJson())).toList());
  }

  Future<void> _savePolygons() async {
    final prefs = await SharedPreferences.getInstance();
    final map = _buildingPolygons.map(
      (id, coords) => MapEntry(id, jsonEncode(coords)));
    await prefs.setString(_polygonsKey, jsonEncode(map));
  }

  Future<void> _loadPolygons() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_polygonsKey);
      if (raw == null) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      for (final e in map.entries) {
        final coords = (jsonDecode(e.value as String) as List)
            .map((c) => (c as List).map((v) => (v as num).toDouble()).toList())
            .toList();
        _buildingPolygons[e.key] = coords;
      }
    } catch (_) {}
  }

  Future<void> _loadPins() async {
    final prefs = await SharedPreferences.getInstance();
    await _loadPolygons();
    final list = prefs.getStringList(_prefsKey) ?? [];
    for (final raw in list) {
      try {
        final pin = CapsulePin.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        if (pin.photoPath == null || File(pin.photoPath!).existsSync()) {
          _pins.add(pin);
          await _sendPinToUnity(pin);
          if (!_buildingPolygons.containsKey(pin.id)) {
            await Future.delayed(const Duration(seconds: 2));
            await _queryBuildingForPin(pin);
            await _savePolygons();
          }
        }
      } catch (_) {}
    }
    _sendFogToUnity();
  }

  // ── Unity에 핀 전송 ──────────────────────────────────────────

  Future<void> _sendPinToUnity(CapsulePin pin) async {
    String? base64Photo;
    if (pin.photo != null && pin.photo!.existsSync()) {
      final bytes = await pin.photo!.readAsBytes();
      base64Photo = base64Encode(bytes);
    }
    _sendToUnity('add_pin', jsonEncode({
      'id': pin.id,
      'lat': pin.lat,
      'lng': pin.lng,
      'title': pin.title,
      'photoBase64': base64Photo ?? '',
    }));
  }

  void _sendFogToUnity() {
    final polygons = _buildingPolygons.entries.map((e) => {
      'pinId': e.key,
      'coords': e.value.map((c) => {'lat': c[1], 'lng': c[0]}).toList(),
    }).toList();
    _sendToUnity('update_fog', jsonEncode({'polygons': polygons}));
  }

  // ── 핀 탭 처리 (Unity → Flutter) ────────────────────────────

  void _onPinTapped(Map<String, dynamic> data) {
    final id = data['id'] as String? ?? '';
    final pin = _pins.firstWhere(
      (p) => p.id == id,
      orElse: () => CapsulePin(id: '', lat: 0, lng: 0, title: ''),
    );
    if (pin.id.isNotEmpty) _showPinSheet(pin);
  }

  // ── OSM Overpass API ─────────────────────────────────────────

  Future<void> _queryBuildingForPin(CapsulePin pin) async {
    final lat = pin.lat, lng = pin.lng;

    Future<Map<String, dynamic>?> overpassGet(String q) async {
      final url = Uri.parse(
        'https://overpass-api.de/api/interpreter?data=${Uri.encodeComponent(q)}');
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          final res = await http.get(url).timeout(const Duration(seconds: 15));
          if (res.statusCode == 200)
            return jsonDecode(res.body) as Map<String, dynamic>;
          if (res.statusCode == 429)
            await Future.delayed(Duration(seconds: attempt * 5));
          else break;
        } catch (e) {
          debugPrint('Overpass 오류: $e'); break;
        }
      }
      return null;
    }

    List<List<double>>? _extractPolygon(Map<String, dynamic> body) {
      final elements = body['elements'] as List?;
      if (elements == null || elements.isEmpty) return null;
      for (final el in elements) {
        final map  = el as Map;
        final geom = map['geometry'] as List?;
        if (geom != null && geom.length >= 3) {
          return geom.map((n) => [
            (n['lon'] as num).toDouble(),
            (n['lat'] as num).toDouble(),
          ]).toList();
        }
      }
      return null;
    }

    try {
      final areaQ =
          '[out:json];is_in($lat,$lng)->.a;('
          'way["tourism"](pivot.a);way["leisure"="park"](pivot.a);'
          'way["historic"](pivot.a);way["amenity"="university"](pivot.a);'
          'relation["tourism"](pivot.a);relation["leisure"="park"](pivot.a);'
          ');out geom;';
      final areaBody = await overpassGet(areaQ);
      if (areaBody != null) {
        final p = _extractPolygon(areaBody);
        if (p != null) { _buildingPolygons[pin.id] = p; return; }
      }

      final buildingBody = await overpassGet(
        '[out:json];way["building"](around:50,$lat,$lng);out geom;');
      if (buildingBody != null) {
        final p = _extractPolygon(buildingBody);
        if (p != null) { _buildingPolygons[pin.id] = p; return; }
      }

      _buildingPolygons[pin.id] = _makeCirclePolygon(lat, lng, 80);
    } catch (e) {
      debugPrint('건물 쿼리 오류: $e');
      _buildingPolygons[pin.id] = _makeCirclePolygon(lat, lng, 80);
    }
  }

  List<List<double>> _makeCirclePolygon(double lat, double lng, double r,
      {int pts = 36}) {
    const m = 111320.0;
    final mLng = m * math.cos(lat * math.pi / 180);
    return List.generate(pts + 1, (i) {
      final a = 2 * math.pi * i / pts;
      return [lng + r * math.cos(a) / mLng, lat + r * math.sin(a) / m];
    });
  }

  // ── 사진 추가 ────────────────────────────────────────────────

  Future<void> addPhotoPin() async {
    if (!await Permission.photos.isGranted)
      await Permission.photos.request();

    final picked = await _picker.pickImage(
      source: img_picker.ImageSource.gallery, requestFullMetadata: true);
    if (picked == null) return;

    setState(() => _isLoading = true);
    try {
      final rawBytes = await picked.readAsBytes();
      geo.Position? gpsPos = await _extractGps(rawBytes);

      if (gpsPos == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('📍 GPS 정보 없음. 현재 위치를 사용합니다.'),
            duration: Duration(seconds: 3),
          ));
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
        photoPath: picked.path,
        title: '타임캡슐 ${_pins.length + 1}',
      );

      _pins.add(pin);
      await _sendPinToUnity(pin);
      await _savePins();

      _sendToUnity('move_camera', jsonEncode({
        'lat': gpsPos.latitude, 'lng': gpsPos.longitude,
        'zoom': 18.0, 'pitch': 65.0,
      }));

      await Future.delayed(const Duration(milliseconds: 800));
      await _queryBuildingForPin(pin);
      await _savePolygons();
      _sendFogToUnity();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('오류: $e')));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── GPS EXIF 추출 ────────────────────────────────────────────

  Future<geo.Position?> _extractGps(Uint8List bytes) async {
    try {
      final data = await readExifFromBytes(bytes);
      if (!data.containsKey('GPS GPSLatitude') ||
          !data.containsKey('GPS GPSLongitude')) return null;

      double? parseDMS(IfdTag tag) {
        final vals = tag.values.toList();
        if (vals.length < 3) return null;
        double? toD(dynamic v) {
          try {
            return (v.numerator as num).toDouble() /
                   (v.denominator as num).toDouble();
          } catch (_) {
            return double.tryParse(v.toString());
          }
        }
        final d = toD(vals[0]), m = toD(vals[1]), s = toD(vals[2]);
        if (d == null || m == null || s == null) return null;
        return d + m / 60.0 + s / 3600.0;
      }

      double? lat = parseDMS(data['GPS GPSLatitude']!);
      double? lng = parseDMS(data['GPS GPSLongitude']!);
      if (lat == null || lng == null) return null;
      if (data['GPS GPSLatitudeRef']?.printable == 'S')  lat = -lat;
      if (data['GPS GPSLongitudeRef']?.printable == 'W') lng = -lng;

      return geo.Position(
        latitude: lat, longitude: lng,
        timestamp: DateTime.now(),
        accuracy: 0, altitude: 0, altitudeAccuracy: 0,
        heading: 0, headingAccuracy: 0, speed: 0, speedAccuracy: 0,
      );
    } catch (_) { return null; }
  }

  // ── 핀 상세 바텀시트 ─────────────────────────────────────────

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
              width: 40, height: 4,
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
            Text(pin.title,
              style: const TextStyle(
                fontSize: 20, fontWeight: FontWeight.bold,
                color: Color(0xFF2E2B2A),
              )),
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

  // ── 빌드 ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      body: Stack(
        children: [
          UnityWidget(
            onUnityCreated: _onUnityCreated,
            onUnityMessage: _onUnityMessage,
            useAndroidViewSurface: true,
            fullscreen: false,
          ),
          if (!_unityReady)
            Container(
              color: const Color(0xFF05101F),
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Color(0xFF7B5EA7)),
                    SizedBox(height: 16),
                    Text('지도 로딩 중...', style: TextStyle(color: Colors.white70)),
                  ],
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
            bottom: 100, right: 16,
            child: _MapFab(
              heroTag: 'photo',
              backgroundColor: const Color(0xFF7B5EA7),
              icon: Icons.add_photo_alternate,
              onPressed: addPhotoPin,
            ),
          ),
          Positioned(
            bottom: 30, right: 16,
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
          width: 56, height: 56,
          child: Icon(icon, color: iconColor, size: 24),
        ),
      ),
    );
  }
}
