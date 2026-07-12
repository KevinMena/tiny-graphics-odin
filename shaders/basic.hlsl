cbuffer Uniform : register(b0, space1) {
    float4x4 mvp;
}

struct VS_INPUT {
    float3 pos   : TEXCOORD0; // Maps to Attribute Location 0
    float4 color : TEXCOORD1; // Maps to Attribute Location 1
};

struct VS_OUTPUT {
    float4 pos : SV_POSITION;
    float4 color : COLOR0;
};

// Vertex Shader: Generates three points of a triangle
VS_OUTPUT MainVS(VS_INPUT input) {
    VS_OUTPUT output;

    float4 local_pos = float4(input.pos, 1.0);

    output.pos = mul(mvp, local_pos);
    output.color = input.color;

    return output;
}

// Fragment Shader: Outputs the interpolated color
float4 MainPS(VS_OUTPUT input) : SV_TARGET {
    return input.color;
}