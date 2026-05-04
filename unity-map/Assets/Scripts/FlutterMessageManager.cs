using System;
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// Flutter ↔ Unity 간 JSON 메시지 브릿지
/// Flutter → Unity : SendMessageToUnity() 경유 → OnFlutterMessage()
/// Unity  → Flutter: FlutterMessageManager.Send()
/// </summary>
public class FlutterMessageManager : MonoBehaviour
{
    public static FlutterMessageManager Instance { get; private set; }

    // 메시지 타입별 핸들러 등록
    private readonly Dictionary<string, Action<string>> _handlers = new();

    void Awake()
    {
        if (Instance != null && Instance != this) { Destroy(gameObject); return; }
        Instance = this;
        DontDestroyOnLoad(gameObject);
    }

    // Flutter → Unity: 메시지 수신 (Flutter 플러그인이 이 메서드를 호출)
    public void OnFlutterMessage(string json)
    {
        try
        {
            var msg = JsonUtility.FromJson<FlutterMessage>(json);
            if (msg == null || string.IsNullOrEmpty(msg.type)) return;

            if (_handlers.TryGetValue(msg.type, out var handler))
                handler?.Invoke(msg.payload);
            else
                Debug.LogWarning($"[Flutter] 처리되지 않은 메시지 타입: {msg.type}");
        }
        catch (Exception e)
        {
            Debug.LogError($"[Flutter] 메시지 파싱 오류: {e.Message}\n{json}");
        }
    }

    // 핸들러 등록
    public void Register(string type, Action<string> handler)
        => _handlers[type] = handler;

    // Unity → Flutter: 메시지 송신
    public static void Send(string type, string payload = "")
    {
        var json = JsonUtility.ToJson(new FlutterMessage { type = type, payload = payload });
#if UNITY_ANDROID && !UNITY_EDITOR
        using var unityPlayer = new AndroidJavaClass("com.unity3d.player.UnityPlayer");
        var activity = unityPlayer.GetStatic<AndroidJavaObject>("currentActivity");
        activity.Call("onUnityMessage", json);
#elif UNITY_IOS && !UNITY_EDITOR
        NativeAPI.SendMessageToFlutter(json);
#else
        Debug.Log($"[Unity→Flutter] {json}");
#endif
    }
}

[Serializable]
public class FlutterMessage
{
    public string type;
    public string payload;
}
