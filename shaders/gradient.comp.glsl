#version 460

layout (local_size_x = 32, local_size_y = 32) in;

layout(rgba16f,set = 0, binding = 0) uniform image2D image;

//push constants block
layout( push_constant ) uniform constants
{
 vec4 data1;
 vec4 data2;
 vec4 data3;
 vec4 data4;
} PushConstants;

void main() 
{
    // Get the texel coordinates for the current invocation
    ivec2 texelCoord = ivec2(gl_GlobalInvocationID.xy);
    
    // Get the size of the image
    ivec2 size = imageSize(image);
    // // Translate the fragment shader code to work in the compute shader
    vec3 white = PushConstants.data1.xyz;
    vec3 black = PushConstants.data2.xyz; 
    
    float scale = 8.0; // Adjust this value to change the size of the tiles
    int x = int(floor(float(texelCoord.x) / scale));
    int y = int(floor(float(texelCoord.y) / scale));
    
    float checker = mod(float(abs(x + y)), 2.0); // Alternates between 0 and 1
    vec3 color = mix(white, black, checker);
    // vec3 color = (checker < 1.0) ? white : black;
    // Write the result to the image
    if (texelCoord.x < size.x && texelCoord.y < size.y){
        imageStore(image, texelCoord, vec4(color, 1.0));
    }
}




// #version 450
// layout (local_size_x = 16, local_size_y = 16) in;
// layout(rgba8,set = 0, binding = 0) uniform image2D image;
//
// // License Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License.
//
// //push constants block
// layout( push_constant ) uniform constants
// {
//  vec4 data1;
//  vec4 data2;
//  vec4 data3;
//  vec4 data4;
// } PushConstants;
//
// // Return random noise in the range [0.0, 1.0], as a function of x.
// float Noise2d( in vec2 x )
// {
//     float xhash = cos( x.x * 0.1 );
//     float yhash = cos( x.y * 0.1 );
//     return fract( 4.0 * ( xhash + yhash ) );
// }
//
// // Convert Noise2d() into a "star field" by stomping everthing below fThreshhold to zero.
// float NoisyStarField( in vec2 vSamplePos, float fThreshhold )
// {
//     float StarVal = Noise2d( vSamplePos );
//     if ( StarVal >= fThreshhold )
//         StarVal = pow( (StarVal - fThreshhold)/(1.0 - fThreshhold), 6.0 );
//     else
//         StarVal = 0.0;
//     return StarVal;
// }
//
// // Stabilize NoisyStarField() by only sampling at integer values.
// float StableStarField( in vec2 vSamplePos, float fThreshhold )
// {
//     // Linear interpolation between four samples.
//     // Note: This approach has some visual artifacts.
//     // There must be a better way to "anti alias" the star field.
//     float fractX = fract( vSamplePos.x );
//     float fractY = fract( vSamplePos.y );
//     vec2 floorSample = floor( vSamplePos );    
//     float v1 = NoisyStarField( floorSample, fThreshhold );
//     float v2 = NoisyStarField( floorSample + vec2( 0.0, 1.0 ), fThreshhold );
//     float v3 = NoisyStarField( floorSample + vec2( 1.0, 0.0 ), fThreshhold );
//     float v4 = NoisyStarField( floorSample + vec2( 1.0, 1.0 ), fThreshhold );
//
//     float StarVal =   v1 * ( 1.0 - fractX ) * ( 1.0 - fractY )
//         			+ v2 * ( 1.0 - fractX ) * fractY
//         			+ v3 * fractX * ( 1.0 - fractY )
//         			+ v4 * fractX * fractY;
// 	return StarVal;
// }
//
// void mainImage( out vec4 fragColor, in vec2 fragCoord )
// {
//     vec2 iResolution = imageSize(image);
// 	// Sky Background Color
// 	//vec3 vColor = vec3( 0.1, 0.2, 0.4 ) * fragCoord.y / iResolution.y;
//     vec3 vColor = PushConstants.data1.xyz * fragCoord.y / iResolution.y;
//
//     // Note: Choose fThreshhold in the range [0.99, 0.9999].
//     // Higher values (i.e., closer to one) yield a sparser starfield.
//     float StarFieldThreshhold = PushConstants.data1.w;//0.97;
//
//     // Stars with a slow crawl.
//     float xRate = 0.2;
//     float yRate = -0.06;
//     vec2 vSamplePos = fragCoord.xy + vec2( xRate * float( 1 ), yRate * float( 1 ) );
// 	float StarVal = StableStarField( vSamplePos, StarFieldThreshhold );
//     vColor += vec3( StarVal );
// 	
// 	fragColor = vec4(vColor, 1.0);
// }
//
//
//
// void main() 
// {
// 	vec4 value = vec4(0.0, 0.0, 0.0, 1.0);
//     ivec2 texelCoord = ivec2(gl_GlobalInvocationID.xy);
// 	ivec2 size = imageSize(image);
//     if(texelCoord.x < size.x && texelCoord.y < size.y)
//     {
//         vec4 color;
//         mainImage(color,texelCoord);
//     
//         imageStore(image, texelCoord, color);
//     }   
// }
//
