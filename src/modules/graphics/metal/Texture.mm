/**
 * Copyright (c) 2006-2022 LOVE Development Team
 *
 * This software is provided 'as-is', without any express or implied
 * warranty.  In no event will the authors be held liable for any damages
 * arising from the use of this software.
 *
 * Permission is granted to anyone to use this software for any purpose,
 * including commercial applications, and to alter it and redistribute it
 * freely, subject to the following restrictions:
 *
 * 1. The origin of this software must not be misrepresented; you must not
 *    claim that you wrote the original software. If you use this software
 *    in a product, an acknowledgment in the product documentation would be
 *    appreciated but is not required.
 * 2. Altered source versions must be plainly marked as such, and must not be
 *    misrepresented as being the original software.
 * 3. This notice may not be removed or altered from any source distribution.
 **/

#include "Texture.h"
#include "Graphics.h"

namespace love
{
namespace graphics
{
namespace metal
{

static MTLTextureType getMTLTextureType(TextureType type, int msaa)
{
	switch (type)
	{
		case TEXTURE_2D: return msaa > 1 ? MTLTextureType2DMultisample : MTLTextureType2D;
		case TEXTURE_VOLUME: return MTLTextureType3D;
		case TEXTURE_2D_ARRAY: return MTLTextureType2DArray;
		case TEXTURE_CUBE: return MTLTextureTypeCube;
		case TEXTURE_MAX_ENUM: return MTLTextureType2D;
	}
	return MTLTextureType2D;
}

Texture::Texture(love::graphics::Graphics *gfxbase, id<MTLDevice> device, const Settings &settings, const Slices *data)
	: love::graphics::Texture(gfxbase, settings, data)
	, texture(nil)
	, msaaTexture(nil)
	, sampler(nil)
	, actualMSAASamples(1)
{ @autoreleasepool {
	auto gfx = (Graphics *) gfxbase;

	MTLTextureDescriptor *desc = [MTLTextureDescriptor new];

	int w = pixelWidth;
	int h = pixelHeight;

	desc.width = w;
	desc.height = h;
	desc.depth = depth;
	desc.arrayLength = layers;
	desc.mipmapLevelCount = mipmapCount;
	desc.textureType = getMTLTextureType(texType, 1);
	if (@available(macOS 10.15, iOS 13, *))
	{
		// We already don't really support metal on older systems, this just
		// silences a compiler warning about it.
		auto formatdesc = Metal::convertPixelFormat(device, format, sRGB);
		desc.pixelFormat = formatdesc.format;
		if (formatdesc.swizzled)
			desc.swizzle = formatdesc.swizzle;
	}
	else
		throw love::Exception("Metal backend is only supported on macOS 10.15+ and iOS 13+.");
	desc.storageMode = MTLStorageModePrivate;

	if (readable)
		desc.usage |= MTLTextureUsageShaderRead;
	if (renderTarget)
		desc.usage |= MTLTextureUsageRenderTarget;

	texture = [device newTextureWithDescriptor:desc];

	if (texture == nil)
		throw love::Exception("Out of graphics memory.");

	actualMSAASamples = gfx->getClosestMSAASamples(getRequestedMSAA());

	if (actualMSAASamples > 1)
	{
		desc.sampleCount = actualMSAASamples;
		desc.textureType = getMTLTextureType(texType, actualMSAASamples);
		desc.usage &= ~MTLTextureUsageShaderRead;

		// TODO: This needs to be cleared, etc.
		msaaTexture = [device newTextureWithDescriptor:desc];
		if (msaaTexture == nil)
		{
			texture = nil;
			throw love::Exception("Out of graphics memory.");
		}
	}

	int mipcount = getMipmapCount();

	int slicecount = 1;
	if (texType == TEXTURE_VOLUME)
		slicecount = getDepth();
	else if (texType == TEXTURE_2D_ARRAY)
		slicecount = getLayerCount();
	else if (texType == TEXTURE_CUBE)
		slicecount = 6;

	for (int mip = 0; mip < mipcount; mip++)
	{
		for (int slice = 0; slice < slicecount; slice++)
		{
			auto imgd = data != nullptr ? data->get(slice, mip) : nullptr;
			if (imgd != nullptr)
				uploadImageData(imgd, mip, slice, 0, 0);
		}
	}

	if (data == nullptr || data->get(0, 0) == nullptr)
	{
		// Initialize all slices to transparent black.
		if (!isPixelFormatDepthStencil(format))
		{
			std::vector<uint8> emptydata(getPixelFormatSliceSize(format, w, h));
			Rect r = {0, 0, w, h};
			for (int i = 0; i < slicecount; i++)
				uploadByteData(format, emptydata.data(), emptydata.size(), 0, i, r);
		}
		else
		{
			// TODO
		}
	}

	// Non-readable textures can't have mipmaps (enforced in the base class),
	// so generateMipmaps here is fine - when they aren't already initialized.
	if (getMipmapCount() > 1 && (data == nullptr || data->getMipmapCount() <= 1))
		generateMipmaps();

	setSamplerState(samplerState);
}}

Texture::~Texture()
{ @autoreleasepool {
	texture = nil;
	msaaTexture = nil;
	sampler = nil;
}}

void Texture::uploadByteData(PixelFormat pixelformat, const void *data, size_t size, int level, int slice, const Rect &r)
{ @autoreleasepool {
	auto gfx = Graphics::getInstance();
	id<MTLBuffer> buffer = [gfx->device newBufferWithBytes:data
													length:size
												   options:MTLResourceStorageModeShared];

	memcpy(buffer.contents, data, size);

	id<MTLBlitCommandEncoder> encoder = gfx->useBlitEncoder();

	int z = 0;
	if (texType == TEXTURE_VOLUME)
	{
		z = slice;
		slice = 0;
	}

	MTLBlitOption options = MTLBlitOptionNone;

	switch (pixelformat)
	{
#ifdef LOVE_IOS
	case PIXELFORMAT_PVR1_RGB2_UNORM:
	case PIXELFORMAT_PVR1_RGB4_UNORM:
	case PIXELFORMAT_PVR1_RGBA2_UNORM:
	case PIXELFORMAT_PVR1_RGBA4_UNORM:
		options |= MTLBlitOptionRowLinearPVRTC;
		break;
#endif
	default:
		break;
	}

	size_t rowSize = 0;
	if (isCompressed())
		rowSize = getPixelFormatCompressedBlockRowSize(format, r.w);
	else
		rowSize = getPixelFormatUncompressedRowSize(format, r.w);

	// TODO: Verify this is correct for compressed formats at small sizes.
	size_t sliceSize = getPixelFormatSliceSize(format, r.w, r.h);

	[encoder copyFromBuffer:buffer
			   sourceOffset:0
		  sourceBytesPerRow:rowSize
		sourceBytesPerImage:sliceSize
				 sourceSize:MTLSizeMake(r.w, r.h, 1)
				  toTexture:texture
		   destinationSlice:slice
		   destinationLevel:level
		  destinationOrigin:MTLOriginMake(r.x, r.y, z)
					options:options];
}}

void Texture::generateMipmapsInternal()
{ @autoreleasepool {
	// TODO: alternate method for non-color-renderable and non-filterable
	// pixel formats.
	id<MTLBlitCommandEncoder> encoder = Graphics::getInstance()->useBlitEncoder();
	[encoder generateMipmapsForTexture:texture];
}}

void Texture::readbackImageData(love::image::ImageData *imagedata, int slice, int mipmap, const Rect &rect)
{ @autoreleasepool {
	auto gfx = Graphics::getInstance();

	id<MTLBlitCommandEncoder> encoder = gfx->useBlitEncoder();

	size_t rowSize = 0;
	if (isCompressed())
		rowSize = getPixelFormatCompressedBlockRowSize(format, rect.w);
	else
		rowSize = getPixelFormatUncompressedRowSize(format, rect.w);

	// TODO: Verify this is correct for compressed formats at small sizes.
	// TODO: make sure this is consistent with the imagedata byte size?
	size_t sliceSize = getPixelFormatSliceSize(format, rect.w, rect.h);

	int z = texType == TEXTURE_VOLUME ? slice : 0;

	id<MTLBuffer> buffer = [gfx->device newBufferWithLength:sliceSize
													options:MTLResourceStorageModeShared];

	MTLBlitOption options = MTLBlitOptionNone;
	if (isPixelFormatDepthStencil(format))
		options = MTLBlitOptionDepthFromDepthStencil;

	[encoder copyFromTexture:texture
				 sourceSlice:texType == TEXTURE_VOLUME ? 0 : slice
				 sourceLevel:mipmap
				sourceOrigin:MTLOriginMake(rect.x, rect.y, z)
				  sourceSize:MTLSizeMake(rect.w, rect.h, 1)
					toBuffer:buffer
		   destinationOffset:0
	  destinationBytesPerRow:rowSize
	destinationBytesPerImage:sliceSize
					 options:options];

	id<MTLCommandBuffer> cmd = gfx->getCommandBuffer();

	gfx->submitBlitEncoder();
	gfx->submitCommandBuffer(Graphics::SUBMIT_STORE);

	[cmd waitUntilCompleted];

	memcpy(imagedata->getData(), buffer.contents, imagedata->getSize());
}}

void Texture::copyFromBuffer(love::graphics::Buffer *source, size_t sourceoffset, int sourcewidth, size_t size, int slice, int mipmap, const Rect &rect)
{ @autoreleasepool {
	id<MTLBlitCommandEncoder> encoder = Graphics::getInstance()->useBlitEncoder();
	id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)(void *) source->getHandle();

	size_t rowSize = 0;
	if (isCompressed())
		rowSize = getPixelFormatCompressedBlockRowSize(format, sourcewidth);
	else
		rowSize = getPixelFormatUncompressedRowSize(format, sourcewidth);

	int z = texType == TEXTURE_VOLUME ? slice : 0;

	MTLBlitOption options = MTLBlitOptionNone;
	if (isPixelFormatDepthStencil(format))
		options = MTLBlitOptionDepthFromDepthStencil;

	[encoder copyFromBuffer:buffer
			   sourceOffset:sourceoffset
		  sourceBytesPerRow:rowSize
		sourceBytesPerImage:size
				 sourceSize:MTLSizeMake(rect.w, rect.h, 1)
				  toTexture:texture
		   destinationSlice:texType == TEXTURE_VOLUME ? 0 : slice
		   destinationLevel:mipmap
		  destinationOrigin:MTLOriginMake(rect.x, rect.y, z)
					options:options];
}}

void Texture::copyToBuffer(love::graphics::Buffer *dest, int slice, int mipmap, const Rect &rect, size_t destoffset, int destwidth, size_t size)
{ @autoreleasepool {
	id<MTLBlitCommandEncoder> encoder = Graphics::getInstance()->useBlitEncoder();
	id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)(void *) dest->getHandle();

	size_t rowSize = 0;
	if (isCompressed())
		rowSize = getPixelFormatCompressedBlockRowSize(format, destwidth);
	else
		rowSize = getPixelFormatUncompressedRowSize(format, destwidth);

	int z = texType == TEXTURE_VOLUME ? slice : 0;

	MTLBlitOption options = MTLBlitOptionNone;
	if (isPixelFormatDepthStencil(format))
		options = MTLBlitOptionDepthFromDepthStencil;

	[encoder copyFromTexture:texture
				 sourceSlice:texType == TEXTURE_VOLUME ? 0 : slice
				 sourceLevel:mipmap
				sourceOrigin:MTLOriginMake(rect.x, rect.y, z)
				  sourceSize:MTLSizeMake(rect.w, rect.h, 1)
					toBuffer:buffer
		   destinationOffset:destoffset
	  destinationBytesPerRow:rowSize
	destinationBytesPerImage:size
					 options:options];
}}

void Texture::setSamplerState(const SamplerState &s)
{ @autoreleasepool {
	// Base class does common validation and assigns samplerState.
	love::graphics::Texture::setSamplerState(s);

	sampler = Graphics::getInstance()->getCachedSampler(s);
}}

} // metal
} // graphics
} // love