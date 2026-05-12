#include "inc_input_structures.slang"

struct VSOutput
{
    float4 pos : SV_Position;
    [vk_location(0)]
    float3 outNormal : NORMAL;
    [vk_location(1)]
    float3 outColor : COLOR;
    [vk_location(2)]
    float2 outUV : TEXCOORD0;
};

struct PushConstants
{
    float4x4 render_matrix;
    uint2 vertex_buffer_pad;
};

[vk_push_constant]
PushConstants push_constants;

[shader("vertex")]
VSOutput main(
    [vk_location(0)] float3 in_position : POSITION,
    [vk_location(1)] float in_uv_x : TEXCOORD1,
    [vk_location(2)] float3 in_normal : NORMAL,
    [vk_location(3)] float in_uv_y : TEXCOORD2,
    [vk_location(4)] float4 in_color : COLOR0)
{
    float4 position = float4(in_position, 1.0);

    VSOutput output;
    output.pos = mul(scene_data.view_proj, mul(push_constants.render_matrix, position));
    output.outNormal = (mul(push_constants.render_matrix, float4(in_normal, 0.0))).xyz;
    output.outColor = in_color.xyz * material_data.color_factors.xyz;
    output.outUV = float2(in_uv_x, in_uv_y);

    return output;
}
