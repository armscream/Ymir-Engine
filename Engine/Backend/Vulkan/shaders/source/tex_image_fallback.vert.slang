struct VSOutput
{
    float4 pos : SV_Position;
    [vk_location(0)]
    float3 color : COLOR0;
    [vk_location(1)]
    float2 uv : TEXCOORD0;
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
    VSOutput output;
    output.pos = mul(push_constants.render_matrix, float4(in_position, 1.0));
    output.color = in_color.xyz;
    output.uv = float2(in_uv_x, in_uv_y);
    return output;
}
