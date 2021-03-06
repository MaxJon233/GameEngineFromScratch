#import <MetalKit/MetalKit.h>
#import <simd/simd.h>

#import "Metal2GraphicsManager.h"
#import "Metal2Renderer.h"

#include "IApplication.hpp"

using namespace My;

// The max number of command buffers in flight
static const NSUInteger GEFSMaxBuffersInFlight = GfxConfiguration::kMaxInFlightFrameCount;

@implementation Metal2Renderer
{
    dispatch_semaphore_t _inFlightSemaphore;
    id<MTLCommandQueue> _commandQueue;
    id<MTLCommandBuffer> _commandBuffer;
    id<MTLCommandBuffer> _computeCommandBuffer;
    MTLRenderPassDescriptor* _renderPassDescriptor;
    id<MTLRenderCommandEncoder> _renderEncoder;
    id<MTLComputeCommandEncoder> _computeEncoder;

    // Metal objects
    id<MTLBuffer> _uniformBuffers[GEFSMaxBuffersInFlight];
    id<MTLBuffer> _lightInfo[GEFSMaxBuffersInFlight];
    std::vector<id<MTLBuffer>> _vertexBuffers;
    std::vector<id<MTLBuffer>> _indexBuffers;
    std::vector<id<MTLTexture>>  _textures;
    id<MTLSamplerState> _sampler0;

    // The index in uniform buffers in _dynamicUniformBuffers to use for the current frame
    uint32_t _currentBufferIndex;

    MTKView* _mtkView;

    // skybox texture id
    int32_t _skyboxTexIndex;
    int32_t _brdfLutIndex;
}

/// Initialize with the MetalKit view from which we'll obtain our Metal device.  We'll also use this
/// mtkView object to set the pixel format and other properties of our drawable
- (nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView device:(id<MTLDevice>) device
{
    self = [super init];
    if(self)
    {
        _currentBufferIndex = 0;
        _mtkView = mtkView;
        _device = device;
        _inFlightSemaphore = dispatch_semaphore_create(GEFSMaxBuffersInFlight);
        _skyboxTexIndex = -1;
        [self loadMetal];
    }

    return self;
}

/// Create our metal render state objects including our shaders and render state pipeline objects
- (void) loadMetal
{

    NSError *error = Nil;
    // Create and load our basic Metal state objects

    for(NSUInteger i = 0; i < GEFSMaxBuffersInFlight; i++)
    {
        // Create and allocate our uniform buffer object.  Indicate shared storage so that both the
        // CPU can access the buffer
        _uniformBuffers[i] = [_device newBufferWithLength:kSizePerFrameConstantBuffer
                                                     options:MTLResourceStorageModeShared];

        _uniformBuffers[i].label = [NSString stringWithFormat:@"uniformBuffer%lu", i];
        
        _lightInfo[i] = [_device newBufferWithLength:kSizeLightInfo options:MTLResourceStorageModeShared];
        
        _lightInfo[i].label = [NSString stringWithFormat:@"lightInfo%lu", i];
    }

   ////////////////////////////
    // Sampler

    MTLSamplerDescriptor* samplerDescriptor = [[MTLSamplerDescriptor alloc] init];
    samplerDescriptor.minFilter = MTLSamplerMinMagFilterLinear;
    samplerDescriptor.magFilter = MTLSamplerMinMagFilterLinear;
    samplerDescriptor.mipFilter = MTLSamplerMipFilterLinear;
    samplerDescriptor.rAddressMode = MTLSamplerAddressModeRepeat;
    samplerDescriptor.sAddressMode = MTLSamplerAddressModeRepeat;
    samplerDescriptor.tAddressMode = MTLSamplerAddressModeRepeat;

    _sampler0 = [_device newSamplerStateWithDescriptor:samplerDescriptor];
    [samplerDescriptor release];

    // Create the command queue
    _commandQueue = [_device newCommandQueue];
}

- (void)createVertexBuffer:(const SceneObjectVertexArray&)v_property_array
{
    id<MTLBuffer> vertexBuffer;
    auto dataSize = v_property_array.GetDataSize();
	auto pData = v_property_array.GetData();
    vertexBuffer = [_device newBufferWithBytes:pData length:dataSize options:MTLResourceStorageModeShared];
    _vertexBuffers.push_back(vertexBuffer);
}

- (void)createIndexBuffer:(const SceneObjectIndexArray&)index_array
{
    id<MTLBuffer> indexBuffer;
    auto dataSize = index_array.GetDataSize();
	auto pData = index_array.GetData();
    indexBuffer = [_device newBufferWithBytes:pData length:dataSize options:MTLResourceStorageModeShared];
    _indexBuffers.push_back(indexBuffer);
}

static MTLPixelFormat getMtlPixelFormat(const Image& img)
{
    MTLPixelFormat format;

    if (img.compressed)
    {
        switch (img.compress_format)
        {
            case "DXT1"_u32:
                format = MTLPixelFormatBC1_RGBA;
                break;
            case "DXT3"_u32:
                format = MTLPixelFormatBC3_RGBA;
                break;
            case "DXT5"_u32:
                format = MTLPixelFormatBC5_RGUnorm;
                break;
            default:
                std::cerr << img << std::endl;
                assert(0);
        }
    }
    else
    {
        switch (img.bitcount)
        {
        case 8:
            format = MTLPixelFormatR8Unorm;
            break;
        case 16:
            format = MTLPixelFormatRG8Unorm;
            break;
        case 32:
            format = MTLPixelFormatRGBA8Unorm;
            break;
        case 64:
            if (img.is_float)
            {
                format = MTLPixelFormatRGBA16Float;
            }
            else
            {
                format = MTLPixelFormatRGBA16Unorm;
            }
            break;
        case 128:
            if (img.is_float)
            {
                format = MTLPixelFormatRGBA32Float;
            }
            else
            {
                format = MTLPixelFormatRGBA32Uint;
            }
            break;
        default:
            assert(0);
        }
    }

    return format;
}

- (uint32_t)createTexture:(const Image&)image
{
    id<MTLTexture> texture;
    MTLTextureDescriptor* textureDesc = [[MTLTextureDescriptor alloc] init];

    textureDesc.pixelFormat = getMtlPixelFormat(image);
    textureDesc.width = image.Width;
    textureDesc.height = image.Height;

    // create the texture obj
    texture = [_device newTextureWithDescriptor:textureDesc];
    [textureDesc release];

    // now upload the data
    MTLRegion region = {
        { 0, 0, 0 },                   // MTLOrigin
        {image.Width, image.Height, 1} // MTLSize
    };

    [texture replaceRegion:region
                mipmapLevel:0
                withBytes:image.data
                bytesPerRow:image.pitch];

    uint32_t index = _textures.size();
    _textures.push_back(texture);

    return index;
}

- (uint32_t)createSkyBox:(const std::vector<const std::shared_ptr<My::Image>>&)images;
{
    id<MTLTexture> texture;

    assert(images.size() == 18); // 6 sky-cube + 6 irrandiance + 6 radiance

    MTLTextureDescriptor* textureDesc = [[MTLTextureDescriptor alloc] init];

    textureDesc.textureType = MTLTextureTypeCubeArray;
    textureDesc.arrayLength = 2;
    textureDesc.pixelFormat = getMtlPixelFormat(*images[0]);
    textureDesc.width = images[0]->Width;
    textureDesc.height = images[0]->Height;
    textureDesc.mipmapLevelCount = std::max(images[16]->mipmaps.size(), (size_t)2);

    // create the texture obj
    texture = [_device newTextureWithDescriptor:textureDesc];

    // now upload the skybox 
    for (int32_t slice = 0; slice < 6; slice++)
    {
        assert(images[slice]->mipmaps.size() == 1);
        MTLRegion region = {
            { 0, 0, 0 },                                        // MTLOrigin
            {images[slice]->Width, images[slice]->Height, 1}    // MTLSize
        };

        [texture replaceRegion:region
                    mipmapLevel:0
                    slice:slice
                    withBytes:images[slice]->data
                    bytesPerRow:images[slice]->pitch
                    bytesPerImage:images[slice]->data_size];
    }

    // now upload the irradiance map as 2nd mip of skybox
    for (int32_t slice = 6; slice < 12; slice++)
    {
        assert(images[slice]->mipmaps.size() == 1);
        MTLRegion region = {
            { 0, 0, 0 },                                        // MTLOrigin
            {images[slice]->Width, images[slice]->Height, 1}    // MTLSize
        };

        [texture replaceRegion:region
                    mipmapLevel:1
                    slice:slice - 6
                    withBytes:images[slice]->data
                    bytesPerRow:images[slice]->pitch
                    bytesPerImage:images[slice]->data_size];
    }

    // now upload the radiance map 2nd cubemap
    for (int32_t slice = 12; slice < 18; slice++)
    {
        int level = 0;
        for (auto& mip : images[slice]->mipmaps)
        {
            MTLRegion region = {
                { 0, 0, 0 },                                                                // MTLOrigin
                {mip.Width, mip.Height, 1}  // MTLSize
            };

            [texture replaceRegion:region
                        mipmapLevel:level++
                        slice:slice - 6
                        withBytes:images[slice]->data + mip.offset
                        bytesPerRow:mip.pitch
                        bytesPerImage:mip.data_size];
        }
    }

    uint32_t index = _textures.size();
    _textures.push_back(texture);

    return index;
}

/// Called whenever view changes orientation or layout is changed
- (void)updateDrawableSize:(CGSize)size
{
#if 0
    /// React to resize of our draw rect.  In particular update our perspective matrix
    // Update the aspect ratio and projection matrix since the view orientation or size has changed
    float aspect = size.width / (float)size.height;

    _projectionMatrix = matrix_perspective_left_hand(65.0f * (M_PI / 180.0f), aspect, 0.1f, 100.0);
#endif
}

- (void)beginFrame:(const My::Frame&)frame
{
    // Wait to ensure only GEFSMaxBuffersInFlight are getting processed by any stage in the Metal
    // pipeline (App, Metal, Drivers, GPU, etc)
    dispatch_semaphore_wait(_inFlightSemaphore, DISPATCH_TIME_FOREVER);

    // Create a new command buffer for each render pass to the current drawable
    _commandBuffer = [_commandQueue commandBuffer];
    _commandBuffer.label = @"myCommand";

    // Obtain a renderPassDescriptor generated from the view's drawable textures
    _renderPassDescriptor = _mtkView.currentRenderPassDescriptor;

    if(_renderPassDescriptor != nil)
    {
        _renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.2f, 0.3f, 0.4f, 1.0f);
    }

    [self setPerFrameConstants:frame.frameContext];
    [self setLightInfo:frame.lightInfo];
}

- (void)endFrame
{
    [_commandBuffer presentDrawable:_mtkView.currentDrawable];

    // Add completion hander which signals _inFlightSemaphore when Metal and the GPU has fully
    // finished processing the commands we're encoding this frame.
    __block dispatch_semaphore_t block_sema = _inFlightSemaphore;
    [_commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer)
     {
         dispatch_semaphore_signal(block_sema);
     }];

    // Finalize rendering here & push the command buffer to the GPU
    [_commandBuffer commit];

    _currentBufferIndex = (_currentBufferIndex + 1) % GEFSMaxBuffersInFlight;
}

- (void)beginPass
{
    if(_renderPassDescriptor != nil)
    {
        _renderEncoder =
            [_commandBuffer renderCommandEncoderWithDescriptor:_renderPassDescriptor];
        _renderEncoder.label = @"MyRenderEncoder";
    }
}

- (void)endPass
{
    [_renderEncoder endEncoding];
}

- (void)beginCompute
{
    // Create a new command buffer for each render pass to the current drawable
    _computeCommandBuffer = [_commandQueue commandBuffer];
    _computeCommandBuffer.label = @"MyComputeCommand";

    _computeEncoder = [_computeCommandBuffer computeCommandEncoder];
    _computeEncoder.label = @"MyComputeEncoder";
}

- (void)endCompute
{
    [_computeEncoder endEncoding];

    // Finalize rendering here & push the command buffer to the GPU
    [_computeCommandBuffer commit];
}

- (void)setPipelineState:(const MetalPipelineState&)pipelineState frameContext:(const Frame&)frame
{
    switch(pipelineState.pipelineType)
    {
        case PIPELINE_TYPE::GRAPHIC:
        {
            switch(pipelineState.cullFaceMode)
            {
                case CULL_FACE_MODE::NONE:
                    [_renderEncoder setCullMode:MTLCullModeNone];
                    break;
                case CULL_FACE_MODE::FRONT:
                    [_renderEncoder setCullMode:MTLCullModeFront];
                    break;
                case CULL_FACE_MODE::BACK:
                    [_renderEncoder setCullMode:MTLCullModeBack];
                    break;
                default:
                    assert(0);
            }
            [_renderEncoder setFrontFacingWinding:MTLWindingCounterClockwise];
            [_renderEncoder setRenderPipelineState:pipelineState.mtlRenderPipelineState];
            [_renderEncoder setDepthStencilState:pipelineState.depthState];
        }
        break;
        case PIPELINE_TYPE::COMPUTE:
        {
            [_computeEncoder setComputePipelineState:pipelineState.mtlComputePipelineState];
        }
        break;
        default:
            assert(0);
    }

    [_renderEncoder setVertexBuffer:_uniformBuffers[_currentBufferIndex]
                                offset:0
                                atIndex:10];

    [_renderEncoder setFragmentBuffer:_uniformBuffers[_currentBufferIndex]
                                offset:0
                                atIndex:10];

    [_renderEncoder setFragmentBuffer:_lightInfo[_currentBufferIndex]
                                offset:0
                                atIndex:12];

    [_renderEncoder setFragmentSamplerState:_sampler0 atIndex:0];

    if (_skyboxTexIndex >= 0)
    {
        [_renderEncoder setFragmentTexture:_textures[_skyboxTexIndex]
                                atIndex:10];
    }

    [_renderEncoder setFragmentTexture:_textures[_brdfLutIndex]
                                atIndex:6];

}

- (void)setPerFrameConstants:(const DrawFrameContext&)context
{
    std::memcpy(_uniformBuffers[_currentBufferIndex].contents, 
            &static_cast<const PerFrameConstants&>(context), sizeof(PerFrameConstants));
}

- (void)setLightInfo:(const LightInfo&)lightInfo
{
    std::memcpy(_lightInfo[_currentBufferIndex].contents,
            &lightInfo, sizeof(LightInfo));
}

- (void)drawSkyBox
{
    if(_renderPassDescriptor != nil)
    {
        // Push a debug group allowing us to identify render commands in the GPU Frame Capture tool
        [_renderEncoder pushDebugGroup:@"DrawSkyBox"];

        if (_skyboxTexIndex >= 0)
        {
            [_renderEncoder setFragmentTexture:_textures[_skyboxTexIndex]
                                    atIndex:10];

            [_renderEncoder setFragmentSamplerState:_sampler0 atIndex:0];
        }

        static const float skyboxVertices[] = {
            1.0f,  1.0f,  1.0f,  // 0
            -1.0f,  1.0f,  1.0f,  // 1
            1.0f, -1.0f,  1.0f,  // 2
            1.0f,  1.0f, -1.0f,  // 3
            -1.0f,  1.0f, -1.0f,  // 4
            1.0f, -1.0f, -1.0f,  // 5
            -1.0f, -1.0f,  1.0f,  // 6
            -1.0f, -1.0f, -1.0f   // 7
        };

        [_renderEncoder setVertexBytes:static_cast<const void*>(skyboxVertices)
                                length:sizeof(skyboxVertices)
                               atIndex:0];

        static const uint16_t skyboxIndices[] = {
            4, 7, 5,
            5, 3, 4,

            6, 7, 4,
            4, 1, 6,

            5, 2, 0,
            0, 3, 5,

            6, 1, 0,
            0, 2, 6,

            4, 3, 0,
            0, 1, 4,

            7, 6, 5,
            5, 6, 2
        };

        [_renderEncoder setVertexBuffer:_uniformBuffers[_currentBufferIndex]
                                 offset:0
                                atIndex:10];

        id<MTLBuffer> indexBuffer;
        indexBuffer = [_device newBufferWithBytes:skyboxIndices
                                           length:sizeof(skyboxIndices) 
                                           options:MTLResourceStorageModeShared];
        
        if (indexBuffer != nil)
        {
            // Draw skybox
            [_renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                    indexCount:sizeof(skyboxIndices)/sizeof(skyboxIndices[0])
                                    indexType:MTLIndexTypeUInt16
                                indexBuffer:indexBuffer
                            indexBufferOffset:0];
        }

        [indexBuffer release];

        [_renderEncoder popDebugGroup];
    }
}

// Called whenever the view needs to render
- (void)drawBatch:(const Frame&) frame
{
    if(_renderPassDescriptor != nil)
    {
        // Push a debug group allowing us to identify render commands in the GPU Frame Capture tool
        [_renderEncoder pushDebugGroup:@"DrawMesh"];
        for (const auto& pDbc : frame.batchContexts)
        {
            [_renderEncoder setVertexBytes:pDbc->modelMatrix
                                    length:64
                                    atIndex:11];

            const auto& dbc = dynamic_cast<const MtlDrawBatchContext&>(*pDbc);

            // Set mesh's vertex buffers
            for (uint32_t bufferIndex = 0; bufferIndex < dbc.property_count; bufferIndex++)
            {
                id<MTLBuffer> vertexBuffer = _vertexBuffers[dbc.property_offset + bufferIndex];
                [_renderEncoder setVertexBuffer:vertexBuffer
                                        offset:0
                                    atIndex:bufferIndex];
            }

            // Set any textures read/sampled from our render pipeline
            if (dbc.material.diffuseMap >= 0)
            {
                [_renderEncoder setFragmentTexture:_textures[dbc.material.diffuseMap]
                                        atIndex:0];
            }

            if (dbc.material.normalMap >= 0)
            {
                [_renderEncoder setFragmentTexture:_textures[dbc.material.normalMap]
                                        atIndex:1];
            }

            if (dbc.material.metallicMap >= 0)
            {
                [_renderEncoder setFragmentTexture:_textures[dbc.material.metallicMap]
                                        atIndex:2];
            }

            if (dbc.material.roughnessMap >= 0)
            {
                [_renderEncoder setFragmentTexture:_textures[dbc.material.roughnessMap]
                                        atIndex:3];
            }

            if (dbc.material.aoMap >= 0)
            {
                [_renderEncoder setFragmentTexture:_textures[dbc.material.aoMap]
                                        atIndex:4];
            }

            if (dbc.material.heightMap >= 0)
            {
                [_renderEncoder setFragmentTexture:_textures[dbc.material.heightMap]
                                        atIndex:5];
            }

    #if 0
            [_renderEncoder setFragmentTexture:_brdfLUT
                                    atIndex:6];

            [_renderEncoder setFragmentTexture:_shadowMap
                                    atIndex:7];

            [_renderEncoder setFragmentTexture:_globalShadowMap
                                    atIndex:8];

            [_renderEncoder setFragmentTexture:_cubeShadowMap
                                    atIndex:9];

            [_renderEncoder setFragmentTexture:_skybox
                                    atIndex:10];

            [_renderEncoder setFragmentTexture:_terrainHeightMap
                                    atIndex:11];
    #endif

            // Draw our mesh
            [_renderEncoder drawIndexedPrimitives:dbc.index_mode
                                    indexCount:dbc.index_count
                                    indexType:dbc.index_type
                                    indexBuffer:_indexBuffers[dbc.index_offset]
                            indexBufferOffset:0];
        }

        [_renderEncoder popDebugGroup];
    }
}

- (int32_t)generateShadowMapArray:(const uint32_t)width
                           height:(const uint32_t)height
                            count:(const uint32_t)count
{
    id<MTLTexture> texture;

    MTLTextureDescriptor* textureDesc = [[MTLTextureDescriptor alloc] init];

    textureDesc.textureType = MTLTextureType2DArray;
    textureDesc.arrayLength = count;
    textureDesc.pixelFormat = MTLPixelFormatDepth32Float;
    textureDesc.width = width;
    textureDesc.height = height;
    textureDesc.storageMode = MTLStorageModePrivate;

    // create the texture obj
    texture = [_device newTextureWithDescriptor:textureDesc];

    uint32_t index = _textures.size();
    _textures.push_back(texture);

    [textureDesc release];

    return static_cast<int32_t>(index);
}

- (int32_t)generateCubeShadowMapArray:(const uint32_t)width 
                               height:(const uint32_t)height
                                count:(const uint32_t)count
{
    id<MTLTexture> texture;

    MTLTextureDescriptor* textureDesc = [[MTLTextureDescriptor alloc] init];

    textureDesc.textureType = MTLTextureTypeCubeArray;
    textureDesc.arrayLength = count;
    textureDesc.pixelFormat = MTLPixelFormatDepth32Float;
    textureDesc.width = width;
    textureDesc.height = height;
    textureDesc.storageMode = MTLStorageModePrivate;

    // create the texture obj
    texture = [_device newTextureWithDescriptor:textureDesc];

    uint32_t index = _textures.size();
    _textures.push_back(texture);

    [textureDesc release];

    return static_cast<int32_t>(index);
}

- (void)beginShadowMap:(const Light&)light
             shadowmap:(const int32_t)shadowmap
                 width:(const uint32_t)width
                height:(const uint32_t)height
           layer_index:(const int32_t)layer_index
{

}

- (void)endShadowMap:(const int32_t)shadowmap
         layer_index:(const int32_t)layer_index
{

}

- (void)setShadowMaps:(const Frame&)frame
{

}

- (void)destroyShadowMap:(int32_t&)shadowmap
{
    _textures[shadowmap] = Nil;
}

- (int32_t)generateAndBindTextureForWrite:(const uint32_t)width
                                   height:(const uint32_t)height
                                  atIndex:(const uint32_t)atIndex
{
    id<MTLTexture> texture;
    MTLTextureDescriptor* textureDesc = [MTLTextureDescriptor new];

    textureDesc.pixelFormat = MTLPixelFormatRG32Float;
    textureDesc.width = width;
    textureDesc.height = height;
    textureDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;

    // create the texture obj
    texture = [_device newTextureWithDescriptor:textureDesc];
    [textureDesc release];

    int32_t texture_id = _textures.size();
    _textures.push_back(texture);

    [_computeEncoder setTexture:texture
                   atIndex:atIndex];

    return texture_id;
}

- (void)dispatch:(const uint32_t)width
          height:(const uint32_t)height
           depth:(const uint32_t)depth
{
    // Set the compute kernel's threadgroup size of 16x16
    MTLSize threadgroupSize = MTLSizeMake(1, 1, 1);
    MTLSize threadgroupCount;

    // Calculate the number of rows and columns of threadgroups given the width of the input image
    // Ensure that you cover the entire image (or more) so you process every pixel
    threadgroupCount.width  = (width  + threadgroupSize.width -  1) / threadgroupSize.width;
    threadgroupCount.height = (height + threadgroupSize.height - 1) / threadgroupSize.height;
    threadgroupCount.depth = (depth + threadgroupSize.depth - 1) / threadgroupSize.depth;

    [_computeEncoder dispatchThreadgroups:threadgroupCount
                    threadsPerThreadgroup:threadgroupSize];
}

@end
