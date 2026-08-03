#include <CoreImage/CoreImage.h>
using namespace metal;

// Overlap Crop Kernel: Crops out 16px tile padding borders to prevent grid artifacts.
extern "C" float4 tileCropOverlap(coreimage::sampler img, float paddingLeft, float paddingBottom, coreimage::destination dest) {
    float2 coord = dest.coord() + float2(paddingLeft, paddingBottom);
    return img.sample(coord);
}

// Unsharp Mask Kernel: Contrast & edge sharpening pass post tile-stitching.
extern "C" float4 unsharpMask(coreimage::sampler img, float amount, coreimage::destination dest) {
    float2 dc = dest.coord();
    float4 center = img.sample(dc);
    
    // 3x3 Laplacian edge sampling
    float4 n = img.sample(dc + float2( 0,  1));
    float4 s = img.sample(dc + float2( 0, -1));
    float4 e = img.sample(dc + float2( 1,  0));
    float4 w = img.sample(dc + float2(-1,  0));
    
    float4 blurred = (n + s + e + w) * 0.25;
    float3 detail = center.rgb - blurred.rgb;
    
    return float4(saturate(center.rgb + detail * amount), center.a);
}
