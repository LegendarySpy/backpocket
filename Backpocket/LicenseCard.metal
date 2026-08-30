#include <metal_stdlib>
using namespace metal;

[[ stitchable ]] half4 licenseSheen(
    float2 position,
    half4 color,
    float time,
    float2 size
) {
    float2 uv = position / max(size, float2(1.0));
    float phase = fmod(time * 0.34, 1.8) - 0.35;
    float diagonal = uv.x + uv.y * 0.35;
    float distance = (diagonal - phase) * 8.0;
    float sheen = exp2(-(distance * distance));

    half strength = half(0.22 + sheen * 0.78);
    return color * strength;
}
