using System;
using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using Mapbox.Unity.Map;
using Mapbox.Utils;

/// <summary>
/// Mapbox 3D 지도 제어 + Flutter 메시지 수신/발신
/// </summary>
[RequireComponent(typeof(AbstractMap))]
public class ToriCapsuleMap : MonoBehaviour
{
    [Header("지도 설정")]
    [SerializeField] AbstractMap _map;
    [SerializeField] float _defaultZoom = 16f;
    [SerializeField] float _defaultPitch = 50f;   // 한국 지도 기본 기울기

    [Header("참조")]
    [SerializeField] PinManager _pinManager;
    [SerializeField] FogOverlayRenderer _fogRenderer;

    // 한국 서울 기본 좌표
    private static readonly Vector2d DefaultCenter = new(37.5665, 126.9780);

    void Start()
    {
        _map ??= GetComponent<AbstractMap>();
        _InitMap();
        _RegisterHandlers();
    }

    void _InitMap()
    {
        _map.Initialize(DefaultCenter, (int)_defaultZoom);

        // 3D 건물 레이어 활성화
        var vectorData = _map.VectorData;
        vectorData.FindFeatureSubLayerWithId("building");

        // 카메라 기울기 설정
        Camera.main.transform.rotation = Quaternion.Euler(_defaultPitch, 0f, 0f);

        _map.OnInitialized += _OnMapInitialized;
        _map.OnUpdated    += _OnMapUpdated;
    }

    void _RegisterHandlers()
    {
        var fm = FlutterMessageManager.Instance;
        if (fm == null) { Debug.LogError("FlutterMessageManager 없음"); return; }

        fm.Register("move_camera",    _HandleMoveCamera);
        fm.Register("add_pin",        _HandleAddPin);
        fm.Register("remove_pin",     _HandleRemovePin);
        fm.Register("update_fog",     _HandleUpdateFog);
        fm.Register("set_style",      _HandleSetStyle);
    }

    // ── 지도 이벤트 ──────────────────────────────────────────────

    void _OnMapInitialized()
    {
        FlutterMessageManager.Send("map_ready", "");
        Debug.Log("[Map] 초기화 완료");
    }

    void _OnMapUpdated()
    {
        _fogRenderer?.Refresh();
    }

    // ── Flutter 메시지 핸들러 ─────────────────────────────────────

    void _HandleMoveCamera(string payload)
    {
        var data = JsonUtility.FromJson<MoveCameraPayload>(payload);
        if (data == null) return;

        var target = new Vector2d(data.lat, data.lng);
        _map.UpdateMap(target, data.zoom > 0 ? data.zoom : _defaultZoom);

        // 카메라 부드럽게 이동
        StopAllCoroutines();
        StartCoroutine(_SmoothCamera(data.pitch > 0 ? data.pitch : _defaultPitch));
    }

    void _HandleAddPin(string payload)
    {
        var data = JsonUtility.FromJson<PinPayload>(payload);
        if (data == null) return;
        _pinManager?.AddPin(data);
    }

    void _HandleRemovePin(string payload)
    {
        var data = JsonUtility.FromJson<PinIdPayload>(payload);
        if (data == null) return;
        _pinManager?.RemovePin(data.id);
    }

    void _HandleUpdateFog(string payload)
    {
        var data = JsonUtility.FromJson<FogPayload>(payload);
        if (data == null) return;
        _fogRenderer?.UpdatePolygons(data.polygons);
    }

    void _HandleSetStyle(string payload)
    {
        // Mapbox 스타일 URL 변경
        _map.ImageryLayer.SetLayerSource(
            (ImagerySourceType)Enum.Parse(typeof(ImagerySourceType), payload, true));
    }

    // ── 부드러운 카메라 기울기 애니메이션 ────────────────────────────

    IEnumerator _SmoothCamera(float targetPitch)
    {
        var cam = Camera.main.transform;
        var startEuler = cam.eulerAngles;
        var endEuler   = new Vector3(targetPitch, startEuler.y, startEuler.z);
        float t = 0f;
        while (t < 1f)
        {
            t += Time.deltaTime * 2f;
            cam.eulerAngles = Vector3.Lerp(startEuler, endEuler, Mathf.SmoothStep(0, 1, t));
            yield return null;
        }
        cam.eulerAngles = endEuler;
    }
}

// ── 페이로드 데이터 클래스 ────────────────────────────────────────

[Serializable] public class MoveCameraPayload { public double lat, lng; public float zoom, pitch; }
[Serializable] public class PinIdPayload      { public string id; }

[Serializable]
public class PinPayload
{
    public string id;
    public double lat, lng;
    public string title;
    public string photoBase64; // 사진 썸네일 (Base64 PNG)
}

[Serializable]
public class FogPayload
{
    public List<PolygonData> polygons;
}

[Serializable]
public class PolygonData
{
    public string pinId;
    public List<LatLng> coords;
}

[Serializable]
public class LatLng
{
    public double lat, lng;
}
