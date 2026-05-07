using System;
using System.Collections;
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// Flutter에서 보낸 지오폴리곤을 받아 안개 셰이더를 갱신한다.
/// GameObject 이름: "FogController"
/// </summary>
public class FogController : MonoBehaviour
{
    [Serializable] class GeoPoint  { public double lat, lng; }
    [Serializable] class FogData
    {
        public List<List<GeoPoint>> polygons;
        public List<GeoPoint> centers;
    }

    [Header("References")]
    public Material fogMaterial;   // FogShader.shader 가 적용된 머티리얼
    public Camera   mapCamera;     // Main Camera (orthographic, clear flags = Depth only)

    double _camLat, _camLng, _camZoom;
    FogData _pending;

    void Start()
    {
        // 카메라 기본값 (서울)
        _camLat  = 37.5665;
        _camLng  = 126.9780;
        _camZoom = 16.0;
    }

    void Update()
    {
        if (_pending != null)
        {
            ApplyFog(_pending);
            _pending = null;
        }
        // 시간 흐름 전달
        fogMaterial?.SetFloat("_Time2", Time.time);
    }

    // ── Flutter → Unity 메시지 ────────────────────────────────
    public void UpdateFog(string json)
    {
        try { _pending = JsonUtility.FromJson<FogData>(json); }
        catch (Exception e) { Debug.LogWarning("FogController: " + e.Message); }
    }

    public void UpdateCamera(string json)
    {
        // {"lat":37.5,"lng":126.9,"zoom":16}
        var cam = JsonUtility.FromJson<CamData>(json);
        _camLat  = cam.lat;
        _camLng  = cam.lng;
        _camZoom = cam.zoom;
        if (_pending == null && fogMaterial != null)
            ApplyFog(new FogData { polygons = new(), centers = new() });
    }

    [Serializable] class CamData { public double lat, lng, zoom; }

    // ── 핵심: 지리좌표 → UV 변환 후 셰이더 업데이트 ──────────
    void ApplyFog(FogData data)
    {
        if (fogMaterial == null) return;

        var verts  = new List<Vector2>();
        var starts = new List<int>();
        var counts = new List<int>();

        foreach (var poly in data.polygons)
        {
            if (poly == null || poly.Count < 3) continue;
            starts.Add(verts.Count);
            foreach (var pt in poly)
                verts.Add(GeoToUV(pt.lat, pt.lng));
            counts.Add(poly.Count);
        }

        // 셰이더에 배열 전달 (최대 256 꼭짓점)
        var arr = new Vector2[256];
        for (int i = 0; i < Math.Min(verts.Count, 256); i++) arr[i] = verts[i];
        fogMaterial.SetVectorArray("_ClearedVerts",
            Array.ConvertAll(arr, v => new Vector4(v.x, v.y, 0, 0)));
        fogMaterial.SetInt("_ClearedVertCount", Math.Min(verts.Count, 256));

        var si = new int[32];
        var sc = new int[32];
        for (int i = 0; i < Math.Min(starts.Count, 32); i++) { si[i] = starts[i]; sc[i] = counts[i]; }
        fogMaterial.SetIntArray("_ClearedPolyStarts", si);
        fogMaterial.SetIntArray("_ClearedPolyCounts", sc);
        fogMaterial.SetInt("_ClearedPolyCount", Math.Min(starts.Count, 32));
    }

    // 위경도 → [0,1] UV (현재 카메라 중심 기준)
    Vector2 GeoToUV(double lat, double lng)
    {
        double metersPerDeg = 111320.0;
        double scale = Math.Pow(2, _camZoom) / 256.0 * metersPerDeg;
        double dx = (lng - _camLng) * metersPerDeg * Math.Cos(_camLat * Math.PI / 180.0);
        double dy = (lat - _camLat) * metersPerDeg;
        // 화면 크기 (임시 고정 – 실제로는 Screen.width/height 사용)
        float sw = Screen.width;
        float sh = Screen.height;
        float x = (float)(0.5 + dx * scale / sw);
        float y = (float)(0.5 + dy * scale / sh);
        return new Vector2(x, y);
    }
}
