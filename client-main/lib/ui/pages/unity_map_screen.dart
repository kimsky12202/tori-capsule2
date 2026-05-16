import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_unity_widget/flutter_unity_widget.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:permission_handler/permission_handler.dart';

class UnityMapScreen extends StatefulWidget {
  const UnityMapScreen({super.key});

  @override
  State<UnityMapScreen> createState() => _UnityMapScreenState();
}

class _UnityMapScreenState extends State<UnityMapScreen>
    with AutomaticKeepAliveClientMixin {
  UnityWidgetController? _unityController;
  StreamSubscription<geo.Position>? _posSub;
  bool _unityReady = false;
  bool _loadTimeout = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _requestLocationPermission();
    // 15초 후에도 안 뜨면 타임아웃 표시
    Future.delayed(const Duration(seconds: 15), () {
      if (mounted && !_unityReady) {
        setState(() => _loadTimeout = true);
      }
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _unityController?.dispose();
    super.dispose();
  }

  Future<void> _requestLocationPermission() async {
    final status = await Permission.location.request();
    if (status.isGranted) {
      _startLocationTracking();
    }
  }

  void _startLocationTracking() {
    _posSub = geo.Geolocator.getPositionStream(
      locationSettings: const geo.LocationSettings(
        accuracy: geo.LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen(_sendLocationToUnity);
  }

  void _sendLocationToUnity(geo.Position pos) {
    if (!_unityReady || _unityController == null) return;
    final json = jsonEncode({
      'lat': pos.latitude,
      'lng': pos.longitude,
      'zoom': 16.0,
    });
    // Unity의 FogController.UpdateCamera(json) 호출
    _unityController!.postMessage('FogController', 'UpdateCamera', json);
    // Unity의 Map 오브젝트에도 위치 전달
    _unityController!.postMessage('Map', 'UpdateLocation', json);
  }

  Future<void> _moveToMyLocation() async {
    try {
      final pos = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.high,
        ),
      );
      _sendLocationToUnity(pos);
    } catch (e) {
      debugPrint('위치 오류: $e');
    }
  }

  void _onUnityCreated(UnityWidgetController controller) {
    _unityController = controller;
    setState(() => _unityReady = true);
    _moveToMyLocation();
  }

  void _onUnityMessage(dynamic message) {
    debugPrint('Unity 메시지: $message');
  }

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
          ),
          if (!_unityReady)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_loadTimeout)
                    const CircularProgressIndicator(color: Color(0xFF7B5EA7)),
                  const SizedBox(height: 16),
                  Text(_loadTimeout ? 'Unity 로드 실패\n앱을 재시작해주세요' : '지도 로딩 중...'),
                ],
              ),
            ),
          Positioned(
            bottom: 30,
            right: 16,
            child: _MapFab(
              heroTag: 'unity_location',
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
