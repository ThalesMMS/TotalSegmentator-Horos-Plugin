#ifndef __OsiriX_Lion__OPJSupport__
#define __OsiriX_Lion__OPJSupport__

#ifdef __cplusplus
    extern "C" void decompressJPEG2KWithBuffer(void* inputBuffer, void* jp2Data, long jp2DataSize, long *decompressedBufferSize, int *colorModel);

    #include <iostream>

    class OPJSupport {
        
    public:
        OPJSupport();
        ~OPJSupport();
        
        void* decompressJPEG2K( void* jp2Data, long jp2DataSize, long *decompressedBufferSize, int *colorModel);
        void* decompressJPEG2KWithBuffer( void* inputBuffer, void* jp2Data, long jp2DataSize, long *decompressedBufferSize, int *colorModel);
        
        unsigned char *compressJPEG2K(   void *data,
                                      int samplesPerPixel,
                                      int rows,
                                      int columns,
                                      int bitsstored, //precision,
                                      unsigned char bitsAllocated,
                                      bool sign,
                                      int rate,
                                      long *compressedDataSize);
    };

#else
    void decompressJPEG2KWithBuffer(void* inputBuffer, void* jp2Data, long jp2DataSize, long *decompressedBufferSize, int *colorModel);
#endif

#endif /* defined(__OsiriX_Lion__OPJSupport__) */
