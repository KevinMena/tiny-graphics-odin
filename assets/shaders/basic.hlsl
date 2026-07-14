cbuffer VertexUniform : register(b0, space1) {
    float4x4 mvp;
}

cbuffer FragmentUniform : register(b0, space3) {
    float4 tex_color;
}

Texture2D    main_texture : register(t0, space2);
SamplerState main_sampler : register(s0, space2);

struct VS_INPUT {
    float3 pos   : TEXCOORD0; // Maps to Attribute Location 0
    float2 uv    : TEXCOORD1; // Maps to Attribute Location 1
    float4 color : TEXCOORD2; // Maps to Attribute Location 2
};

struct VS_OUTPUT {
    float4 pos : SV_POSITION;
    float4 color : COLOR0;
    float2 uv    : TEXCOORD0;
};

// Vertex Shader: Generates three points of a triangle
VS_OUTPUT MainVS(VS_INPUT input) {
    VS_OUTPUT output;

    float4 local_pos = float4(input.pos, 1.0);

    output.pos = mul(mvp, local_pos);
    output.color = input.color;
    output.uv = input.uv;

    return output;
}

// Fragment Shader: Outputs the interpolated color
float4 MainPS(VS_OUTPUT input) : SV_TARGET {
    float4 base_color = main_texture.Sample(main_sampler, input.uv);

    return base_color * tex_color * input.color;
}