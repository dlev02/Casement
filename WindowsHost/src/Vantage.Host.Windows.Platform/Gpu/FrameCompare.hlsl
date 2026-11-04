// Change estimate for captures without dirty regions (Windows before 11 24H2): one thread group
// per 32×32 block compares the new frame with the last one this pass saw, writes 1 (changed) or
// 0 into the block map, and copies the changed pixels into Previous, so the next frame is compared
// with this one without a separate full-frame copy. Compiled at runtime (FrameComparer).
//
// Previous is R32_UINT (packed RGB): typed UAV loads are guaranteed only for 32-bit formats on
// feature level 11.0. Alpha is ignored (desktop capture alpha is always 1).

Texture2D<float4> Current : register(t0);
RWTexture2D<uint> Previous : register(u0);
RWTexture2D<uint> Blocks : register(u1);

groupshared uint s_changed;

uint Pack(float4 colour)
{
    uint3 c = (uint3)round(saturate(colour.rgb) * 255.0);
    return c.r | (c.g << 8) | (c.b << 16);
}

[numthreads(32, 32, 1)]
void main(uint3 group : SV_GroupID, uint3 local : SV_GroupThreadID, uint index : SV_GroupIndex)
{
    if (index == 0) s_changed = 0;
    GroupMemoryBarrierWithGroupSync();

    uint width, height;
    Current.GetDimensions(width, height);
    uint2 pixel = group.xy * 32 + local.xy;
    if (pixel.x < width && pixel.y < height)
    {
        uint now = Pack(Current[pixel]);
        if (now != Previous[pixel])
        {
            Previous[pixel] = now;
            InterlockedOr(s_changed, 1);
        }
    }

    GroupMemoryBarrierWithGroupSync();
    if (index == 0) Blocks[group.xy] = s_changed;
}
