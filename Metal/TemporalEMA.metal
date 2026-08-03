#include <CoreImage/CoreImage.h>
using namespace metal;

// Temporal Exponential Moving Average (EMA) Anti-Flicker Filter:
// Blends current frame with previous upscaled frame history (mix(prev.rgb, curr.rgb, alpha)).
// Locks high-frequency generative noise in place over time to eliminate video flickering.
extern "C" float4 temporalEMAFilter(coreimage::sampler current, coreimage::sampler previous, float alpha, coreimage::destination dest) {
    float2 dc = dest.coord();
    float4 curr = current.sample(dc);
    float4 prev = previous.sample(dc);
    
    // Smooth transition; fallback to current frame if previous is uninitialized or outside extent
    float3 blended = mix(prev.rgb, curr.rgb, saturate(alpha));
    return float4(saturate(blended), curr.a);
}
