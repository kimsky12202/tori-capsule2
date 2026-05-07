Shader "Custom/FogOfWar"
{
    Properties
    {
        _FogColor ("Fog Color", Color) = (0.78, 0.84, 0.88, 0.85)
        _EdgeSoftness ("Edge Softness", Range(0.001, 0.1)) = 0.02
        _NoiseScale ("Noise Scale", Range(1, 20)) = 6.0
        _NoiseStrength ("Noise Strength", Range(0, 0.05)) = 0.015
        _Time2 ("Time", Float) = 0
    }

    SubShader
    {
        Tags { "Queue"="Transparent" "RenderType"="Transparent" }
        Blend SrcAlpha OneMinusSrcAlpha
        ZWrite Off
        Cull Off

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "UnityCG.cginc"

            struct appdata { float4 vertex : POSITION; float2 uv : TEXCOORD0; };
            struct v2f    { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };

            fixed4 _FogColor;
            float  _EdgeSoftness;
            float  _NoiseScale;
            float  _NoiseStrength;
            float  _Time2;

            // Simplex-style 2D noise
            float2 hash2(float2 p) {
                p = float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)));
                return -1.0 + 2.0 * frac(sin(p) * 43758.5453123);
            }
            float noise(float2 p) {
                float2 i = floor(p);
                float2 f = frac(p);
                float2 u = f * f * (3.0 - 2.0 * f);
                return lerp(
                    lerp(dot(hash2(i + float2(0,0)), f - float2(0,0)),
                         dot(hash2(i + float2(1,0)), f - float2(1,0)), u.x),
                    lerp(dot(hash2(i + float2(0,1)), f - float2(0,1)),
                         dot(hash2(i + float2(1,1)), f - float2(1,1)), u.x),
                    u.y);
            }
            float fbm(float2 p) {
                float v = 0.0;
                v += 0.500 * noise(p);
                v += 0.250 * noise(p * 2.1 + float2(1.7, 9.2));
                v += 0.125 * noise(p * 4.3 + float2(8.3, 2.8));
                return v;
            }

            // 걷힌 구역 판별 (최대 64개 폴리곤 꼭짓점)
            #define MAX_VERTS 256
            uniform float2 _ClearedVerts[MAX_VERTS];
            uniform int    _ClearedVertCount;
            uniform int    _ClearedPolyStarts[32];
            uniform int    _ClearedPolyCounts[32];
            uniform int    _ClearedPolyCount;

            bool pointInPolygon(float2 pt, int start, int count) {
                bool inside = false;
                int j = start + count - 1;
                for (int i = start; i < start + count; i++) {
                    float2 vi = _ClearedVerts[i];
                    float2 vj = _ClearedVerts[j];
                    if (((vi.y > pt.y) != (vj.y > pt.y)) &&
                        (pt.x < (vj.x - vi.x) * (pt.y - vi.y) / (vj.y - vi.y) + vi.x))
                        inside = !inside;
                    j = i;
                }
                return inside;
            }

            float clearedAlpha(float2 uv) {
                float minDist = 9999.0;
                bool cleared = false;
                for (int p = 0; p < _ClearedPolyCount; p++) {
                    if (pointInPolygon(uv, _ClearedPolyStarts[p], _ClearedPolyCounts[p])) {
                        cleared = true;
                        break;
                    }
                }
                if (cleared) return 0.0;

                // 경계 페이드: 가장 가까운 폴리곤 꼭짓점까지 거리
                for (int i = 0; i < _ClearedVertCount; i++) {
                    float d = length(uv - _ClearedVerts[i]);
                    if (d < minDist) minDist = d;
                }
                return smoothstep(0.0, _EdgeSoftness * 2.0, minDist - _EdgeSoftness);
            }

            v2f vert(appdata v) {
                v2f o;
                o.pos = UnityObjectToClipPos(v.vertex);
                o.uv  = v.uv;
                return o;
            }

            fixed4 frag(v2f i) : SV_Target {
                float2 uv = i.uv;
                float alpha = clearedAlpha(uv);
                if (alpha < 0.01) discard;

                // Perlin noise로 안개 텍스처 생성
                float2 noiseUV = uv * _NoiseScale + float2(_Time2 * 0.02, _Time2 * 0.015);
                float n = fbm(noiseUV) * _NoiseStrength;
                uv += n;
                alpha = clearedAlpha(uv) * alpha;

                // 안개 밝기 변화 (자연스러운 농담)
                float density = 0.85 + fbm(uv * 3.0 + float2(_Time2 * 0.01, 0)) * 0.15;

                fixed4 col = _FogColor;
                col.a *= alpha * density;
                return col;
            }
            CGPROGRAM
            ENDCG
        }
    }
}
