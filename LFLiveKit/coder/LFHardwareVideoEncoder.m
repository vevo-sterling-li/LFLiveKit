//
//  LFHardwareVideoEncoder.m
//  LFLiveKit
//
//  Created by LaiFeng on 16/5/20.
//  Copyright © 2016年 LaiFeng All rights reserved.
//
#import "LFHardwareVideoEncoder.h"
#import <VideoToolbox/VideoToolbox.h>


@interface LFHardwareVideoEncoder (){
    VTCompressionSessionRef compressionSession;
    NSInteger frameCount;
    NSData *sps;
    NSData *pps;
    FILE *fp;
    BOOL enabledWriteVideoFile;
}


@property (nonatomic, strong) LFLiveVideoConfiguration *configuration;
@property (nonatomic, weak) id<LFVideoEncodingDelegate> h264Delegate;
@property (nonatomic) NSInteger currentVideoBitRate;
@property (nonatomic) BOOL isBackGround;
@property (nonatomic,readonly) short height;

@property (nonatomic, assign) BOOL fullyBackground;

@end

@implementation LFHardwareVideoEncoder

#pragma mark - init
- (instancetype)initWithVideoStreamConfiguration:(LFLiveVideoConfiguration *)configuration {
    if (self = [super init]) {
        NSLog(@"USE LFHardwareVideoEncoder");
        _configuration = configuration;
        _height = (short)_configuration.videoSize.height;
        
        [self resetCompressionSession];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(willResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(willEnterForeground:) name:UIApplicationDidBecomeActiveNotification object:nil];
#ifdef DEBUG
        enabledWriteVideoFile = NO;
        [self initForFilePath];
#endif
        
    }
    return self;
}

- (void)dealloc {
    if (compressionSession != NULL) {
        VTCompressionSessionCompleteFrames(compressionSession, kCMTimeInvalid);
        
        VTCompressionSessionInvalidate(compressionSession);
        CFRelease(compressionSession);
        compressionSession = NULL;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


//-----------------------------------------------------------------------------------------------------
#pragma mark - create compression session
- (void)resetCompressionSession {
    fprintf(stdout,"[LFHardwareVideoEncoder/resetCompressionSession]...(%d)\n",(int)_configuration.videoSize.height);
    if (compressionSession) {
        VTCompressionSessionCompleteFrames(compressionSession, kCMTimeInvalid);

        VTCompressionSessionInvalidate(compressionSession);
        CFRelease(compressionSession);
        compressionSession = NULL;
    }

    //create VTCompressionSession with self as arg outputCallbackRefCon
    OSStatus status = VTCompressionSessionCreate(NULL, _configuration.videoSize.width, _configuration.videoSize.height, kCMVideoCodecType_H264, NULL, NULL, NULL, VideoCompressonOutputCallback, (__bridge void *)self, &compressionSession);
    if (status != noErr) {
        return;
    }

    //set both key frame max frame and max duration interval and both will be enforced.  Set both to 0 to let encoder decide
    VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(_configuration.videoMaxKeyframeInterval));
    VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, (__bridge CFTypeRef)@(_configuration.videoMaxKeyframeIntervalDuration));
    
    //set frame rate
    VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@(_configuration.videoFrameRate));
    
    //set constraints on average and max bitrate
    _currentVideoBitRate = _configuration.videoBitRate;
    VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(_configuration.videoBitRate));
    //max data rate unit is byte, so divide bit rate by 8
    //LFLiveKit had this set at 1.5*current bitrate, but that's really really high!  Could end up with a really big frame
    NSArray *limit = @[@((_configuration.videoBitRate + 200 * 1000)/8), @(1)];
    VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_DataRateLimits, (__bridge CFArrayRef)limit);
    
    //limit compression window to 1/2 second, ie how many frames encoder can hold on to before it must emit one
//    VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_MaxFrameDelayCount, (__bridge CFTypeRef)@(15));
    
    //tell encoder to encode in real time
    VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    
    //set H.264 profile
    //iphone 7,X cannot encode 720p at high 4.1 at 0.12 bits/pixel, too many macrobolocks, but can do 3.2
    //iphone 7,X can encode 540p at high 4.1 with an adaptive bitrate bound by 0.6 and 0.19 bits/pixel
    status = VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_4_1); //kVTProfileLevel_H264_Main_AutoLevel);
    assert(status == 0);
    
    //disallow frame reordering because we are not doing B frames
    VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    
    //entropy coding (ie lossless symbol replacement)
    VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC);
    
    //warm up the encoder
    VTCompressionSessionPrepareToEncodeFrames(compressionSession);
}


//-----------------------------------------------------------------------------------------------------
#pragma mark - video bitrate
- (void)setVideoBitRate:(NSInteger)videoBitRate {
    if(_isBackGround) return;
    if (_currentVideoBitRate == videoBitRate) return;
    
    VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(videoBitRate));
    NSArray *limit = @[@(videoBitRate * 1.5/8), @(1)];
    VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_DataRateLimits, (__bridge CFArrayRef)limit);
    
    _currentVideoBitRate = videoBitRate;
    //UGH: double tracking here of same value: _videoConfiguration also has videoBitRate property that should be kept current BECAUSE if we have to reset the compression session, it is _configuration's videoBitRate that gets used
}

- (NSInteger)videoBitRate {
    return _currentVideoBitRate;
}


//-----------------------------------------------------------------------------------------------------
#pragma mark -- encoding
- (void)encodeVideoData:(CVPixelBufferRef)pixelBuffer timeStamp:(uint64_t)timeStamp {
    if(_isBackGround) return;
    
    //fprintf(stdout,"[LFHardwareVideoEncoder/encodeVideoData:timeStamp:]...frame height=%d\n",(int)CVPixelBufferGetHeight(pixelBuffer));
    
    //note: presentationTimestamp is time at which frame should be displayed WHEREAS arg timeStamp simply expresses relative frame order
    
    frameCount++;
    CMTime presentationTimeStamp = CMTimeMake(frameCount, (int32_t)_configuration.videoFrameRate);
    VTEncodeInfoFlags flags;
    CMTime duration = CMTimeMake(1, (int32_t)_configuration.videoFrameRate);

    NSDictionary *properties = nil;
    if (frameCount % (int32_t)_configuration.videoMaxKeyframeInterval == 0) {
        properties = @{(__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES};
    }
    NSNumber *timeNumber = @(timeStamp);    //relative frame order value

    //pass timestamp as sourceFrameRefCon, which gets passed to callback as 2nd arg VTFrameRef
    OSStatus status = VTCompressionSessionEncodeFrame(compressionSession, pixelBuffer, presentationTimeStamp, duration, (__bridge CFDictionaryRef)properties, (__bridge_retained void *)timeNumber, &flags);
    if(status != noErr){
        [self resetCompressionSession];
    }
}

- (void)stopEncoder {   //stop?? fricking good name; what does stop mean? i don't want to stop the encoder, I may want to use it again!
    VTCompressionSessionCompleteFrames(compressionSession, kCMTimeIndefinite);
}

-(void)completeAllFrames {
    //complete all frames up to last submitted
    CMTime presentationTimeStamp = CMTimeMake(frameCount+30, (int32_t)_configuration.videoFrameRate);
    VTCompressionSessionCompleteFrames(compressionSession, presentationTimeStamp);
}

- (void)setDelegate:(id<LFVideoEncodingDelegate>)delegate {
    _h264Delegate = delegate;
}


//-----------------------------------------------------------------------------------------------------
#pragma mark - app lifecycle notifications
- (void)willResignActive:(NSNotification *)notification {
    _fullyBackground = NO;
}

- (void)didEnterBackground:(NSNotification*)notification{
    _fullyBackground = YES;
    _isBackGround = YES;
}

- (void)willEnterForeground:(NSNotification*)notification{
    if (_fullyBackground) {
        [self resetCompressionSession];
        _isBackGround = NO;
    }
    _fullyBackground = NO;
}


//-----------------------------------------------------------------------------------------------------
#pragma mark - compression session callback
static void VideoCompressonOutputCallback(void *VTref, void *VTFrameRef, OSStatus status, VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer){
    if (status != noErr) {
        return;
    }
    
    //check if keyframe, a flag for which is in the sample attachment dictionaries (one dictionary per sample in the CMSampleBuffer)
    if (!sampleBuffer)
        return;
    CFArrayRef array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
    if (!array) return;
    CFDictionaryRef dic = (CFDictionaryRef)CFArrayGetValueAtIndex(array, 0);
    if (!dic) return;
    //if kCMSampleAttachmentKey_NotSync is true, the frame is not a sync sample, aka not a key frame (sync sample = key frame)
    CFBooleanRef notSync;
    BOOL keyExists = CFDictionaryGetValueIfPresent(dic,
                                                   kCMSampleAttachmentKey_NotSync,
                                                   (const void **)&notSync);
    BOOL keyframe = !keyExists || !CFBooleanGetValue(notSync);
    
    //arg sourceFrameRefCon (ie void* VTFrameRef) is an NSNumber wrapping frame's timeStamp THAT reflects relative frame order, NOT presentation timeStamp
    uint64_t timeStamp = [((__bridge_transfer NSNumber *)VTFrameRef) longLongValue];

    //arg1 is outputCallbackRefCon, which in creation we set to self, so we can get access to instance of this class that created the compression session
    LFHardwareVideoEncoder *videoEncoder = (__bridge LFHardwareVideoEncoder *)VTref;
    if (status != noErr) {
        return;
    }

    //seems that if the instance of this class that is running the compression session doesn't have its sps and pps properties set, and we got a keyframe, then sps and pps are in the first CMSampleBuffer received
    //SPS and PPS are **NOT** stored in the data of passed CMSampleBuffer, but instead are in the CMSB's format description!
    //jknote: sps/pps are generated per I-frame, so changed this method so that if an I frame, then update videoEncoder's sps/pps
    if (keyframe) { //} && !videoEncoder->sps) {
//        fprintf(stdout,"[LFHardwareVideoEncoder/VideoCompressionOutputCallback()]...encoder(%d) generated sps\n",(int)videoEncoder.configuration.videoSize.height);
        
        //SPS and PPS are specified in the CMVideoFormatDescriiption in the CMSampleBuffer
        //note CMVideoFormatDescriptionRef is typedef'd to CMFormatDescription
        CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);

        //SPS is at index 0 of the format description
        size_t sparameterSetSize, sparameterSetCount;
        const uint8_t *sparameterSet;
        OSStatus statusCode = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, &sparameterSet, &sparameterSetSize, &sparameterSetCount, 0);
        if (statusCode == noErr) {
            //SPS is at index 1 of the format description
            size_t pparameterSetSize, pparameterSetCount;
            const uint8_t *pparameterSet;
            OSStatus statusCode = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 1, &pparameterSet, &pparameterSetSize, &pparameterSetCount, 0);
            if (statusCode == noErr) {
                videoEncoder->sps = [NSData dataWithBytes:sparameterSet length:sparameterSetSize];
                videoEncoder->pps = [NSData dataWithBytes:pparameterSet length:pparameterSetSize];

                if (videoEncoder->enabledWriteVideoFile) {
                    NSMutableData *data = [[NSMutableData alloc] init];
                    uint8_t header[] = {0x00, 0x00, 0x00, 0x01};
                    [data appendBytes:header length:4];
                    [data appendData:videoEncoder->sps];
                    [data appendBytes:header length:4];
                    [data appendData:videoEncoder->pps];
                    fwrite(data.bytes, 1, data.length, videoEncoder->fp);
                }
            }
        }
    }

    //parse NALU from CMSampleBuffer
    //CMSampleBuffer stores a CMBlockBuffer
    //NALU data in CMBlockBuffer is stored in AVCC format but needs to be converted to Annex B format
    //AVCC format is big endian!
    //good reference: https://stackoverflow.com/questions/28396622/extracting-h264-from-cmblockbuffer
    CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t length, totalLength;
    char *dataPointer;
    OSStatus statusCodeRet = CMBlockBufferGetDataPointer(dataBuffer, 0, &length, &totalLength, &dataPointer);
    if (statusCodeRet == noErr) {
        size_t bufferOffset = 0;
        static const int AVCCHeaderLength = 4;
        
        //there may be multiple NALUs in the CMBlockBuffer
        while (bufferOffset < totalLength - AVCCHeaderLength) {
            //read this NALU's size in bytes
            uint32_t NALUnitLength = 0;
            memcpy(&NALUnitLength, dataPointer + bufferOffset, AVCCHeaderLength);

            //AVCC format is big endian, so convert to little endian
            NALUnitLength = CFSwapInt32BigToHost(NALUnitLength);

            //take NALU bytes after NALU size in bytes entry and make LFVideoFrame
            LFVideoFrame *videoFrame = [LFVideoFrame new];
            videoFrame.timestamp = timeStamp;   //expresses relative frame order
            videoFrame.data = [[NSData alloc] initWithBytes:(dataPointer + bufferOffset + AVCCHeaderLength) length:NALUnitLength];
            videoFrame.isKeyFrame = keyframe;
            videoFrame.height = videoEncoder->_height;
            videoFrame.sps = videoEncoder->sps;
            videoFrame.pps = videoEncoder->pps;

            //send frame to delegate
            if (videoEncoder.h264Delegate && [videoEncoder.h264Delegate respondsToSelector:@selector(videoEncoder:videoFrame:)]) {
                [videoEncoder.h264Delegate videoEncoder:videoEncoder videoFrame:videoFrame];
            }

            if (videoEncoder->enabledWriteVideoFile) {
                //also write to file
                NSMutableData *data = [[NSMutableData alloc] init];
                if (keyframe) {
                    uint8_t header[] = {0x00, 0x00, 0x00, 0x01};        //Annex B start code
                    [data appendBytes:header length:4];
                } else {
                    uint8_t header[] = {0x00, 0x00, 0x01};
                    [data appendBytes:header length:3];
                }
                [data appendData:videoFrame.data];

                fwrite(data.bytes, 1, data.length, videoEncoder->fp);
            }

            //update buffer offset past just parsed NALU; if bufferOffset < totalLength of CMBlockBuffer, there's another NALU to be parsed
            bufferOffset += AVCCHeaderLength + NALUnitLength;
        }
    }
}


///this is UNUSED code from https://stackoverflow.com/questions/28396622/extracting-h264-from-cmblockbuffer and IS included for reference for encoder callback.
//key differences are:
//  -sends SPS/PPS on every I frame
static void videoFrameFinishedEncoding(void *outputCallbackRefCon,
                                       void *sourceFrameRefCon,
                                       OSStatus status,
                                       VTEncodeInfoFlags infoFlags,
                                       CMSampleBufferRef sampleBuffer) {
    // Check if there were any errors encoding
    if (status != noErr) {
        NSLog(@"Error encoding video, err=%lld", (int64_t)status);
        return;
    }
    
    // In this example we will use a NSMutableData object to store the
    // elementary stream.
    NSMutableData *elementaryStream = [NSMutableData data];
    
    
    // Find out if the sample buffer contains an I-Frame.
    // If so we will write the SPS and PPS NAL units to the elementary stream.
    BOOL isIFrame = NO;
    CFArrayRef attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, 0);
    if (CFArrayGetCount(attachmentsArray)) {
        CFBooleanRef notSync;
        CFDictionaryRef dict = CFArrayGetValueAtIndex(attachmentsArray, 0);
        BOOL keyExists = CFDictionaryGetValueIfPresent(dict,
                                                       kCMSampleAttachmentKey_NotSync,
                                                       (const void **)&notSync);
        // An I-Frame is a sync frame
        isIFrame = !keyExists || !CFBooleanGetValue(notSync);
    }
    
    // This is the start code that we will write to
    // the elementary stream before every NAL unit
    static const size_t startCodeLength = 4;
    static const uint8_t startCode[] = {0x00, 0x00, 0x00, 0x01};
    
    // Write the SPS and PPS NAL units to the elementary stream before every I-Frame
    if (isIFrame) {
        CMFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sampleBuffer);
        
        // Find out how many parameter sets there are
        size_t numberOfParameterSets;
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description,
                                                           0, NULL, NULL,
                                                           &numberOfParameterSets,
                                                           NULL);
        
        // Write each parameter set to the elementary stream
        for (int i = 0; i < numberOfParameterSets; i++) {
            const uint8_t *parameterSetPointer;
            size_t parameterSetLength;
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description,
                                                               i,
                                                               &parameterSetPointer,
                                                               &parameterSetLength,
                                                               NULL, NULL);
            
            // Write the parameter set to the elementary stream
            [elementaryStream appendBytes:startCode length:startCodeLength];
            [elementaryStream appendBytes:parameterSetPointer length:parameterSetLength];
        }
    }
    
    // Get a pointer to the raw AVCC NAL unit data in the sample buffer
    size_t blockBufferLength;
    uint8_t *bufferDataPointer = NULL;
    CMBlockBufferGetDataPointer(CMSampleBufferGetDataBuffer(sampleBuffer),
                                0,
                                NULL,
                                &blockBufferLength,
                                (char **)&bufferDataPointer);
    
    // Loop through all the NAL units in the block buffer
    // and write them to the elementary stream with
    // start codes instead of AVCC length headers
    size_t bufferOffset = 0;
    static const int AVCCHeaderLength = 4;
    while (bufferOffset < blockBufferLength - AVCCHeaderLength) {
        // Read the NAL unit length
        uint32_t NALUnitLength = 0;
        memcpy(&NALUnitLength, bufferDataPointer + bufferOffset, AVCCHeaderLength);
        // Convert the length value from Big-endian to Little-endian
        NALUnitLength = CFSwapInt32BigToHost(NALUnitLength);
        // Write start code to the elementary stream
        [elementaryStream appendBytes:startCode length:startCodeLength];
        // Write the NAL unit without the AVCC length header to the elementary stream
        [elementaryStream appendBytes:bufferDataPointer + bufferOffset + AVCCHeaderLength
                               length:NALUnitLength];
        // Move to the next NAL unit in the block buffer
        bufferOffset += AVCCHeaderLength + NALUnitLength;
    }
}



//-----------------------------------------------------------------------------------------------------
#pragma mark - output file utils
- (void)initForFilePath {
    NSString *path = [self GetFilePathByfileName:@"IOSCamDemo.h264"];
    NSLog(@"%@", path);
    self->fp = fopen([path cStringUsingEncoding:NSUTF8StringEncoding], "wb");
}

- (NSString *)GetFilePathByfileName:(NSString*)filename {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *writablePath = [documentsDirectory stringByAppendingPathComponent:filename];
    return writablePath;
}

@end
