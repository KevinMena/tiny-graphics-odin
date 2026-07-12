struct VS_OUTPUT {
    float4 pos : SV_POSITION;
    float4 color : COLOR0;
};

// Vertex Shader: Generates three points of a triangle
VS_OUTPUT MainVS(uint vertexID : SV_VertexID) {
    VS_OUTPUT output;

    // Hardcoded triangle positions in Clip Space (-1 to 1)
    float2 positions[3] = {
        float2( 0.0,  0.5), // Top
        float2( 0.5, -0.5), // Bottom Right
        float2(-0.5, -0.5)  // Bottom Left
    };

    // Hardcoded colors for each vertex
    float3 colors[3] = {
        float3(1.0, 0.0, 0.0), // Red
        float3(0.0, 1.0, 0.0), // Green
        float3(0.0, 0.0, 1.0)  // Blue
    };

    output.pos = float4(positions[vertexID], 0.0, 1.0);
    output.color = float4(colors[vertexID], 1.0);

    return output;
}