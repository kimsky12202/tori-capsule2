using System;
using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using Mapbox.Unity.Map;
using Mapbox.Unity.MeshGeneration.Factories;
using Mapbox.Utils;

/// <summary>
/// 사진 핀 3D 배치 및 탭 이벤트 관리
/// </summary>
public class PinManager : MonoBehaviour
{
    [SerializeField] AbstractMap _map;
    [SerializeField] GameObject  _pinPrefab;   // 핀 프리팹 (원형 사진 + 꼬리)
    [SerializeField] float       _pinAltitude = 10f;

    private readonly Dictionary<string, GameObject> _pins = new();

    // ── 핀 추가 ──────────────────────────────────────────────────

    public void AddPin(PinPayload data)
    {
        if (_pins.ContainsKey(data.id)) return;

        var worldPos = _map.GeoToWorldPosition(
            new Vector2d(data.lat, data.lng), true);
        worldPos.y = _pinAltitude;

        var go = Instantiate(_pinPrefab, worldPos, Quaternion.identity, transform);
        go.name = $"pin_{data.id}";

        // 사진 텍스처 적용
        if (!string.IsNullOrEmpty(data.photoBase64))
            StartCoroutine(_ApplyPhoto(go, data.photoBase64));

        // 터치 이벤트 등록
        var btn = go.GetComponent<PinTouchButton>() ?? go.AddComponent<PinTouchButton>();
        btn.Init(data.id, data.title, _OnPinTapped);

        // 빌보드(항상 카메라 방향) 컴포넌트
        go.AddComponent<Billboard>();

        _pins[data.id] = go;
    }

    public void RemovePin(string id)
    {
        if (!_pins.TryGetValue(id, out var go)) return;
        Destroy(go);
        _pins.Remove(id);
    }

    // ── 지도 업데이트 시 핀 위치 재계산 ─────────────────────────────

    public void RefreshPositions()
    {
        foreach (var kv in _pins)
        {
            var btn = kv.Value.GetComponent<PinTouchButton>();
            if (btn == null) continue;
            var worldPos = _map.GeoToWorldPosition(btn.Coord, true);
            worldPos.y = _pinAltitude;
            kv.Value.transform.position = worldPos;
        }
    }

    // ── 사진 Base64 → Texture2D ──────────────────────────────────

    IEnumerator _ApplyPhoto(GameObject go, string base64)
    {
        yield return null; // 1프레임 대기
        try
        {
            var bytes   = Convert.FromBase64String(base64);
            var tex     = new Texture2D(2, 2);
            tex.LoadImage(bytes);

            var renderer = go.GetComponentInChildren<MeshRenderer>();
            if (renderer != null)
                renderer.material.mainTexture = tex;
        }
        catch (Exception e)
        {
            Debug.LogWarning($"[Pin] 사진 로드 실패: {e.Message}");
        }
    }

    void _OnPinTapped(string id, string title)
    {
        var payload = JsonUtility.ToJson(new PinTapResult { id = id, title = title });
        FlutterMessageManager.Send("pin_tapped", payload);
    }
}

// ── 핀 터치 감지 ─────────────────────────────────────────────────

public class PinTouchButton : MonoBehaviour
{
    public Vector2d Coord { get; private set; }

    private string _id, _title;
    private Action<string, string> _onTap;

    public void Init(string id, string title, Action<string, string> onTap)
    {
        _id    = id;
        _title = title;
        _onTap = onTap;
    }

    void OnMouseDown() => _onTap?.Invoke(_id, _title);
}

// ── 빌보드: 항상 카메라 방향 ──────────────────────────────────────

public class Billboard : MonoBehaviour
{
    void LateUpdate()
    {
        if (Camera.main == null) return;
        transform.LookAt(
            transform.position + Camera.main.transform.rotation * Vector3.forward,
            Camera.main.transform.rotation * Vector3.up);
    }
}

[Serializable] public class PinTapResult { public string id, title; }
