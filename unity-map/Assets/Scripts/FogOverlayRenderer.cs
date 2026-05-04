using System.Collections.Generic;
using UnityEngine;
using Mapbox.Unity.Map;
using Mapbox.Utils;

/// <summary>
/// 핀 주변만 밝고 나머지는 안개(어둠)로 덮는 메시 렌더러
/// GeoJSON 폴리곤 → Unity Mesh Hole 방식
/// </summary>
[RequireComponent(typeof(MeshFilter), typeof(MeshRenderer))]
public class FogOverlayRenderer : MonoBehaviour
{
    [SerializeField] AbstractMap _map;
    [SerializeField] Material    _fogMaterial;   // 반투명 어두운 마테리얼
    [SerializeField] float       _fogAltitude = 5f;
    [SerializeField, Range(0f, 1f)] float _fogOpacity = 0.82f;

    private MeshFilter   _meshFilter;
    private MeshRenderer _meshRenderer;
    private List<PolygonData> _polygons = new();

    void Awake()
    {
        _meshFilter   = GetComponent<MeshFilter>();
        _meshRenderer = GetComponent<MeshRenderer>();

        if (_fogMaterial == null)
        {
            _fogMaterial = new Material(Shader.Find("Transparent/Diffuse"));
            _fogMaterial.color = new Color(0.02f, 0.04f, 0.08f, _fogOpacity);
        }
        _meshRenderer.material = _fogMaterial;
    }

    // Flutter에서 폴리곤 데이터 수신 시 호출
    public void UpdatePolygons(List<PolygonData> polygons)
    {
        _polygons = polygons ?? new List<PolygonData>();
        _BuildMesh();
    }

    // 지도 업데이트 시 메시 재계산 (카메라 이동 후)
    public void Refresh() => _BuildMesh();

    void _BuildMesh()
    {
        if (_map == null) return;

        var vertices  = new List<Vector3>();
        var triangles = new List<int>();

        // 전 세계 덮개 사각형 (지도 타일 범위)
        const float half = 2000f;
        int vBase = 0;

        vertices.AddRange(new[]
        {
            new Vector3(-half, _fogAltitude, -half),
            new Vector3( half, _fogAltitude, -half),
            new Vector3( half, _fogAltitude,  half),
            new Vector3(-half, _fogAltitude,  half),
        });
        triangles.AddRange(new[] { 0, 2, 1, 0, 3, 2 });
        vBase = 4;

        // 각 핀 폴리곤을 "구멍(hole)"으로 뚫기
        foreach (var poly in _polygons)
        {
            if (poly?.coords == null || poly.coords.Count < 3) continue;

            var worldPts = new List<Vector2>();
            foreach (var ll in poly.coords)
            {
                var wp = _map.GeoToWorldPosition(new Vector2d(ll.lat, ll.lng), true);
                worldPts.Add(new Vector2(wp.x, wp.z));
            }

            // Ear-Clipping 삼각분할
            var holeVerts = new List<Vector3>();
            foreach (var pt in worldPts)
                holeVerts.Add(new Vector3(pt.x, _fogAltitude, pt.y));

            var holeTris = _Triangulate(worldPts);
            if (holeTris == null) continue;

            // 구멍 삼각형은 뒤집어서 덮개에서 빼냄
            foreach (var ti in holeTris)
            {
                triangles.Add(vBase + ti[2]);
                triangles.Add(vBase + ti[1]);
                triangles.Add(vBase + ti[0]);
            }
            vertices.AddRange(holeVerts);
            vBase += holeVerts.Count;
        }

        var mesh = new Mesh { name = "FogOverlay" };
        mesh.SetVertices(vertices);
        mesh.SetTriangles(triangles, 0);
        mesh.RecalculateNormals();
        _meshFilter.mesh = mesh;
    }

    // ── Ear-Clipping 삼각분할 ────────────────────────────────────

    List<int[]> _Triangulate(List<Vector2> pts)
    {
        var result  = new List<int[]>();
        var indices = new List<int>();
        for (int i = 0; i < pts.Count; i++) indices.Add(i);

        // 다각형 면적으로 CW/CCW 판단
        float area = 0;
        for (int i = 0; i < pts.Count; i++)
        {
            int j = (i + 1) % pts.Count;
            area += pts[i].x * pts[j].y - pts[j].x * pts[i].y;
        }
        if (area < 0) indices.Reverse();

        int maxIter = pts.Count * pts.Count;
        int iter = 0;
        while (indices.Count > 3 && iter++ < maxIter)
        {
            bool clipped = false;
            for (int i = 0; i < indices.Count; i++)
            {
                int prev = indices[(i - 1 + indices.Count) % indices.Count];
                int curr = indices[i];
                int next = indices[(i + 1) % indices.Count];

                if (!_IsEar(pts, prev, curr, next, indices)) continue;

                result.Add(new[] { prev, curr, next });
                indices.RemoveAt(i);
                clipped = true;
                break;
            }
            if (!clipped) break;
        }

        if (indices.Count == 3)
            result.Add(new[] { indices[0], indices[1], indices[2] });

        return result;
    }

    bool _IsEar(List<Vector2> pts, int prev, int curr, int next, List<int> indices)
    {
        if (_Cross(pts[prev], pts[curr], pts[next]) <= 0) return false;
        foreach (int idx in indices)
        {
            if (idx == prev || idx == curr || idx == next) continue;
            if (_PointInTriangle(pts[idx], pts[prev], pts[curr], pts[next]))
                return false;
        }
        return true;
    }

    float _Cross(Vector2 o, Vector2 a, Vector2 b)
        => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);

    bool _PointInTriangle(Vector2 p, Vector2 a, Vector2 b, Vector2 c)
    {
        float d1 = _Cross(a, b, p), d2 = _Cross(b, c, p), d3 = _Cross(c, a, p);
        bool hasNeg = d1 < 0 || d2 < 0 || d3 < 0;
        bool hasPos = d1 > 0 || d2 > 0 || d3 > 0;
        return !(hasNeg && hasPos);
    }
}
