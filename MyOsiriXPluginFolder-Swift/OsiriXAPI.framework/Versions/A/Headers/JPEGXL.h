//
//  JPEGXL.hpp
//  OsiriX_Lion
//
//  Created by Antoine Rosset on 18.07.2025.
//  Copyright © 2025 OsiriX Team. All rights reserved.
//

#ifndef JPEGXL_hpp
#define JPEGXL_hpp

#include <stdio.h>

#ifdef __cplusplus
#define EXTERNC extern "C"
#else
#define EXTERNC
#endif

EXTERNC void* decompressJPEGXLWithBuffer( void* inputBuffer, void* jp2Data, size_t jp2DataSize, long *decompressedBufferSize, int *colorModel, int num_threads);
EXTERNC void* compressJPEGXL( void *data, int samplesPerPixel, int rows, int columns, int precision, bool sign, float rate, long *compressedDataSize, int num_threads);

#endif /* JPEGXL_hpp */
