//
//  LFLiveSession.m
//  LFLiveKit
//
//  Created by LaiFeng on 16/5/20.
//  Copyright © 2016年 LaiFeng All rights reserved.
//

#import "LFLiveSession.h"
#import "LFVideoCapture.h"
#import "LFAudioCapture.h"
#import "LFHardwareVideoEncoder.h"
#import "LFHardwareAudioEncoder.h"
#import "LFH264VideoEncoder.h"
#import "LFStreamRTMPSocket.h"
#import "LFLiveStreamInfo.h"
#import "LFGPUImageBeautyFilter.h"
#import "LFH264VideoEncoder.h"


@interface LFLiveSession ()<LFAudioCaptureDelegate, LFVideoCaptureDelegate, LFAudioEncodingDelegate, LFVideoEncodingDelegate, LFStreamSocketDelegate>

/// 音频配置
@property (nonatomic, strong) LFLiveAudioConfiguration *audioConfiguration;
/// 视频配置
///videoConfiguration points to either videoConfigurationLow, videoConfigurationMedium, or videoConfigurationHigh
@property (nonatomic, strong) LFLiveVideoConfiguration *videoConfiguration;
@property (nonatomic, strong) LFLiveVideoConfiguration *previousVideoConfiguration;
@property (nonatomic, strong) LFLiveVideoConfiguration *videoConfigurationLow;
@property (nonatomic, strong) LFLiveVideoConfiguration *videoConfigurationMedium;
@property (nonatomic, strong) LFLiveVideoConfiguration *videoConfigurationHigh;

/// 声音采集
@property (nonatomic, strong) LFAudioCapture *audioCaptureSource;
/// 视频采集
@property (nonatomic, strong) LFVideoCapture *videoCaptureSource;
/// 音频编码
@property (nonatomic, strong) id<LFAudioEncoding> audioEncoder;
/// 视频编码
//@property (nonatomic, strong) id<LFVideoEncoding> videoEncoder;
//@property(nonatomic,strong) id<LFVideoEncoding> videoEncoderLow;
//@property(nonatomic,strong) id<LFVideoEncoding> videoEncoderMedium;
//@property(nonatomic,strong) id<LFVideoEncoding> videoEncoderHigh;
@property(nonatomic,strong) LFHardwareVideoEncoder *videoEncoderLow;
@property(nonatomic,strong) LFHardwareVideoEncoder *videoEncoderMedium;
@property(nonatomic,strong) LFHardwareVideoEncoder *videoEncoderHigh;

@property(nonatomic,strong) dispatch_queue_t resolutionChangeQ;
@property(atomic,assign) BOOL isDrainingPreviousEncoder;
@property(nonatomic,strong) NSMutableArray<LFVideoFrame*> *framesAtNewResolutionWaitingToBeSent;

/// 上传
@property (nonatomic, strong) id<LFStreamSocket> socket;


#pragma mark -- 内部标识
/// 调试信息
@property (nonatomic, strong) LFLiveDebug *debugInfo;
/// 流信息
@property (nonatomic, strong) LFLiveStreamInfo *streamInfo;
/// 是否开始上传
@property (nonatomic, assign) BOOL uploading;
/// 当前状态
@property (nonatomic, assign, readwrite) LFLiveState state;
/// 当前直播type
@property (nonatomic, assign, readwrite) LFLiveCaptureTypeMask captureType;
/// 时间戳锁
@property (nonatomic, strong) dispatch_semaphore_t lock;

@property (nonatomic, assign) AVCaptureVideoOrientation capturePreviewVideoOrientation;

@end

/**  时间戳 */
#define NOW (CACurrentMediaTime()*1000)
#define SYSTEM_VERSION_LESS_THAN(v) ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] == NSOrderedAscending)

@interface LFLiveSession ()

/// 上传相对时间戳
@property (nonatomic, assign) uint64_t relativeTimestamps;
/// 音视频是否对齐
@property (nonatomic, assign) BOOL AVAlignment;
/// 当前是否采集到了音频
@property (nonatomic, assign) BOOL hasCaptureAudio;
/// 当前是否采集到了关键帧
@property (nonatomic, assign) BOOL hasKeyFrameVideo;

@end

@implementation LFLiveSession

#pragma mark -- LifeCycle
- (instancetype)initWithAudioConfiguration:(nullable LFLiveAudioConfiguration *)audioConfiguration videoConfiguration:(nullable LFLiveVideoConfiguration *)videoConfiguration {
    return [self initWithAudioConfiguration:audioConfiguration videoConfiguration:videoConfiguration captureType:LFLiveCaptureDefaultMask];
}

- (nullable instancetype)initWithAudioConfiguration:(nullable LFLiveAudioConfiguration *)audioConfiguration
                                 videoConfiguration:(nullable LFLiveVideoConfiguration *)videoConfiguration
                                        captureType:(LFLiveCaptureTypeMask)captureType {
    if((captureType & LFLiveCaptureMaskAudio || captureType & LFLiveInputMaskAudio) && !audioConfiguration) @throw [NSException exceptionWithName:@"LFLiveSession init error" reason:@"audioConfiguration is nil " userInfo:nil];
    if((captureType & LFLiveCaptureMaskVideo || captureType & LFLiveInputMaskVideo) && !videoConfiguration) @throw [NSException exceptionWithName:@"LFLiveSession init error" reason:@"videoConfiguration is nil " userInfo:nil];
    
    if (self = [super init]) {
        _audioConfiguration = audioConfiguration;
        
        //to support adaptive video resolution, create a video encoder for each resolution
        //since changing frame rate is not supported, create low, med, high video configurations based on target frame rate (reflected by value 1, 2, or 3)
        switch (videoConfiguration.videoQuality) {
            case LFLiveVideoQuality_Low1:
                [self createVideoConfigurationsAtResolution1];
                _videoConfiguration = _videoConfigurationLow;
                break;
            case LFLiveVideoQuality_Medium1:
                [self createVideoConfigurationsAtResolution1];
                _videoConfiguration = _videoConfigurationMedium;
                break;
            case LFLiveVideoQuality_High1:
                [self createVideoConfigurationsAtResolution1];
                _videoConfiguration = _videoConfigurationHigh;
                break;
                
            case LFLiveVideoQuality_Low2:
                [self createVideoConfigurationsAtResolution2];
                _videoConfiguration = _videoConfigurationLow;
                break;
            case LFLiveVideoQuality_Medium2:
                [self createVideoConfigurationsAtResolution2];
                _videoConfiguration = _videoConfigurationMedium;
                break;
            case LFLiveVideoQuality_High2:
                [self createVideoConfigurationsAtResolution2];
                _videoConfiguration = _videoConfigurationHigh;
                break;
                
            case LFLiveVideoQuality_Low3:
                [self createVideoConfigurationsAtResolution3];
                _videoConfiguration = _videoConfigurationLow;
                break;
            case LFLiveVideoQuality_Medium3:
                [self createVideoConfigurationsAtResolution3];
                _videoConfiguration = _videoConfigurationMedium;
                break;
            case LFLiveVideoQuality_High3:
                [self createVideoConfigurationsAtResolution3];
                _videoConfiguration = _videoConfigurationHigh;
                break;
            default:
                assert(0);
                break;
        }
        
        //default to zero adaptivity
        _previousVideoConfiguration = nil;
        _adaptiveBitrate = NO;
        _adaptiveResolution = NO;
        dispatch_queue_attr_t priorityAttribute = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, -6);
        _resolutionChangeQ = dispatch_queue_create("com.youku.LaiFeng.resolutionChangeQ", priorityAttribute);
        _isDrainingPreviousEncoder = NO;
        _framesAtNewResolutionWaitingToBeSent = [[NSMutableArray alloc] initWithCapacity:45];    //TODO: configure # frames VTCompressionSession holds on to?
        
        _captureType = captureType;
    }
    return self;
}

- (nullable instancetype)initWithAudioConfiguration:(nullable LFLiveAudioConfiguration *)audioConfiguration
                                 videoConfiguration:(nullable LFLiveVideoConfiguration *)videoConfiguration
                     capturePreviewVideoOrientation:(AVCaptureVideoOrientation)capturePreviewOrientation
{
    if (self = [self initWithAudioConfiguration:audioConfiguration videoConfiguration:videoConfiguration]) {
        self.capturePreviewVideoOrientation = capturePreviewOrientation;
    }
    return self;
}


- (void)dealloc {
    _videoCaptureSource.running = NO;
    _audioCaptureSource.running = NO;
}


//-----------------------------------------------------------------------------------------------------
#pragma mark -- start/stop
- (void)startLive:(LFLiveStreamInfo *)streamInfo {
    if (!streamInfo) return;
    _streamInfo = streamInfo;
    _streamInfo.videoConfiguration = _videoConfiguration;
    _streamInfo.audioConfiguration = _audioConfiguration;
    [self.socket start];
}

- (void)stopLive {
    self.uploading = NO;
    [self.socket stop];
    self.socket = nil;
}


//-----------------------------------------------------------------------------------------------------
#pragma mark - ?
///these seem unused
- (void)pushVideo:(nullable CVPixelBufferRef)pixelBuffer {
    if (self.captureType & LFLiveInputMaskVideo) {
        if (self.uploading) {
            //[self.videoEncoder encodeVideoData:pixelBuffer timeStamp:NOW];
            [self encodePixelBuffer: pixelBuffer timeStamp: NOW];
        }
    }
}

- (void)pushAudio:(nullable NSData*)audioData {
    if (self.captureType & LFLiveInputMaskAudio) {
        if (self.uploading)
            [self.audioEncoder encodeAudioData:audioData timeStamp:NOW];
    }
}


//-----------------------------------------------------------------------------------------------------
//send encoded frame to client
#pragma mark -- PrivateMethod
- (void)pushSendBuffer:(LFFrame*)frame{
    if(self.relativeTimestamps == 0){
        self.relativeTimestamps = frame.timestamp;
    }
    
    frame.timestamp = [self uploadTimestamp: frame.timestamp];
    [self.socket sendFrame: frame];
}


//-----------------------------------------------------------------------------------------------------
//called when capture session instances have readied a new frame for encoding
#pragma mark -- CaptureDelegate
- (void)captureOutput:(nullable LFAudioCapture *)capture audioData:(nullable NSData*)audioData {
    if (self.uploading)
        [self.audioEncoder encodeAudioData:audioData timeStamp: NOW];
}

- (void)captureOutput:(nullable LFVideoCapture *)capture pixelBuffer:(nullable CVPixelBufferRef)pixelBuffer {
    if (self.uploading) {
        //[self.videoEncoder encodeVideoData:pixelBuffer timeStamp:NOW];
        [self encodePixelBuffer: pixelBuffer timeStamp: NOW];
    }
}

///call to target encoder appropriate to pixel buffer resolution
-(void)encodePixelBuffer:(nonnull CVPixelBufferRef)pixelBuffer timeStamp:(uint64_t)timestamp {
    //select correct encoder for pixel buffer based on its image resolution (720p, 540p, 360p, ie based on height param only)
    int bufferHeight = (int) CVPixelBufferGetHeight(pixelBuffer);
    if (bufferHeight == _videoConfigurationLow.videoSize.height) {
        //update encoder video bitrate based on current 'low' configuration, then encode
        [self.videoEncoderLow setVideoBitRate: _videoConfigurationLow.videoBitRate];
        [self.videoEncoderLow encodeVideoData: pixelBuffer timeStamp: timestamp];
    }
    else if (bufferHeight == _videoConfigurationMedium.videoSize.height) {
        //update encoder video bitrate based on current 'medium' configuration, then encode
        [self.videoEncoderMedium setVideoBitRate: _videoConfigurationMedium.videoBitRate];
        [self.videoEncoderMedium encodeVideoData: pixelBuffer timeStamp: timestamp];
    }
    else if (bufferHeight == _videoConfigurationHigh.videoSize.height) {
        //update encoder video bitrate based on current 'high' configuration, then encode
        [self.videoEncoderHigh setVideoBitRate: _videoConfigurationHigh.videoBitRate];
        [self.videoEncoderHigh encodeVideoData: pixelBuffer timeStamp: timestamp];
    }
    else {
        assert(0);  //for debugging
    }
    
    //handle video resolution transition, if one in progress
    //need to trap when first frame of a new resolution comes off the renderer pipeline because we need to transmit all frames at previous resolution before transmit first frame at new resolution
    //SO on receiving from render pipeline first frame at new resolution, do:
    //  1) set flag so that if encoded frames at new resolution are received in videoEncoder:videoFrame… before all frames at previous resolution are encoded and transmitted, they are held in array _framesAtNewResolutionWaitingToBeSent
    //  2) tell encoder of frames of previous resolution to complete all frames
    //FWIW, it's uncertain that any frames at new resolution will be encoded before all frames at previous resolution are complete because encoder of frames at new resolution will be buffering frames for reference for encooding P frames
    if (bufferHeight == _videoConfiguration.videoSize.height && _previousVideoConfiguration) {
        fprintf(stdout,"[LFLiveSession/encodePixelBuffer:timeStamp:]...detected first frame from render pipeline at new resolution..\n");
        //render pipeline won't produce any more frames at previous resolution
        @synchronized(self) {
            _isDrainingPreviousEncoder = YES;
        }
        
        LFHardwareVideoEncoder *previousVideoEncoder;
        switch(_previousVideoConfiguration.videoQuality) {
            case LFLiveVideoQuality_Low1:
            case LFLiveVideoQuality_Low2:
            case LFLiveVideoQuality_Low3:
                previousVideoEncoder = self.videoEncoderLow;
                break;
            case LFLiveVideoQuality_Medium1:
            case LFLiveVideoQuality_Medium2:
            case LFLiveVideoQuality_Medium3:
                previousVideoEncoder = self.videoEncoderMedium;
                break;
            case LFLiveVideoQuality_High1:
            case LFLiveVideoQuality_High2:
            case LFLiveVideoQuality_High3:
                previousVideoEncoder = self.videoEncoderHigh;
                break;
            default:
                assert(0);
        }
        
        //complete encoding all frames of previous resolution. The call to a VTCompressionSession to complete all frames BLOCKS until all frames have been emitted, so have to do it on a special dispatchQ
        dispatch_async(_resolutionChangeQ, ^{
            printf("..(LFLiveSession/encodePixelBuffer:timeStamp:)..<resolutionChangeQ>: telling previous encoder to complete frames..\n");
            [previousVideoEncoder completeAllFrames];   //blocks until all frames have been emitted
            printf("..(LFLiveSession/encodePixelBuffer:timeStamp:)..<resolutionChangeQ>: previous encoder completed frames..\n");
            
            @synchronized(self) {
                _isDrainingPreviousEncoder = NO;
            }
            
            //reset encoder to be ready for next use
            //[previousVideoEncoder resetCompressionSession];
        });
        
        //nil out _previousVideoConfiguration so that we don't enter this if-block again!
        _previousVideoConfiguration = nil;
    }
}


//-----------------------------------------------------------------------------------------------------
#pragma mark -- EncoderDelegate
//encoders callback with encoded frame
- (void)audioEncoder:(nullable id<LFAudioEncoding>)encoder audioFrame:(nullable LFAudioFrame *)frame {
    // 上传  时间戳对齐 (Upload timestamp alignment)
    if (self.uploading){
        self.hasCaptureAudio = YES;
        
        //AVAlignment enforces that, when capturing both audio and video, that we have received both an encoded audio frame and an encoded video frame -- or more likely that we have captured both..that the capture session has provided both an audio and video frame -- is there some configuration here that requires this condition, or is this simply a sanity check that both are working, or is that we don't want to send video that doesn't have audio yet, and vice versa?
        if(self.AVAlignment)
            [self pushSendBuffer:frame];
    }
}

- (void)videoEncoder:(nullable id<LFVideoEncoding>)encoder videoFrame:(nullable LFVideoFrame *)frame {
    // 上传 时间戳对齐 (Upload timestamp alignment)
    if (self.uploading) {
        if(frame.isKeyFrame && self.hasCaptureAudio)
            self.hasKeyFrameVideo = YES;
        
        //AVAlignment enforces that, when capturing both audio and video, that we have received both an encoded audio frame and an encoded video frame -- or more likely that we have captured both..that the capture session has provided both an audio and video frame -- is there some configuration here that requires this condition, or is this simply a sanity check that both are working, or is that we don't want to send video that doesn't have audio yet, and vice versa?
        if (self.AVAlignment) {
            //video frames arrive here from a video encoder
            //..but we have 3 video encoders and if resolution change is allowed, then an arriving frame could be either:
            //  1) a frame at the current resolution arriving outside of any resolution transition
            //  2) a frame at the current resolution arriving during a resolution transition, ie while draining previous resolution encoder and sending those frames
            //  3) a frame at the previous resolution that was drained from encoder of previous resolution frames
            
            if (frame.height != _videoConfiguration.videoSize.height) {
                //frame was drained from encoder of previous resolution and should be sent ASAP
                printf("[LFLiveSession/videoEncoder:videoFrame:]...sending frame of previous resolution\n");
                [self pushSendBuffer:frame];
            }
            else {
                @synchronized(self) {
                    if (_isDrainingPreviousEncoder) {
                        //hold frame till all previous resolution frames are sent
                        printf("[LFLiveSession/videoEncoder:videoFrame:]...holding frame of new resolution during resolution transition\n");
                        [_framesAtNewResolutionWaitingToBeSent addObject:frame];
                    }
                    else {
                        //send frame, but send any we are holding from a resolution transition
                        while ([_framesAtNewResolutionWaitingToBeSent count] > 0) {
                            printf("[LFLiveSession/videoEncoder:videoFrame:]...popping held frame\n");
                            LFVideoFrame* heldFrame = [_framesAtNewResolutionWaitingToBeSent objectAtIndex:0];
                            [self pushSendBuffer:heldFrame];
                            [_framesAtNewResolutionWaitingToBeSent removeObjectAtIndex:0];
                        }
                        
                        [self pushSendBuffer:frame];
                    }
                }
            }
        }
    }
}


//-----------------------------------------------------------------------------------------------------
#pragma mark -- LFStreamTcpSocketDelegate
- (void)socketStatus:(nullable id<LFStreamSocket>)socket status:(LFLiveState)status {
    if (status == LFLiveStart) {
        if (!self.uploading) {
            self.AVAlignment = NO;
            self.hasCaptureAudio = NO;
            self.hasKeyFrameVideo = NO;
            self.relativeTimestamps = 0;
            self.uploading = YES;
        }
    } else if(status == LFLiveStop || status == LFLiveError){
        self.uploading = NO;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        self.state = status;
        if (self.delegate && [self.delegate respondsToSelector:@selector(liveSession:liveStateDidChange:)]) {
            [self.delegate liveSession:self liveStateDidChange:status];
        }
    });
}

- (void)socketDidError:(nullable id<LFStreamSocket>)socket errorCode:(LFLiveSocketErrorCode)errorCode {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.delegate && [self.delegate respondsToSelector:@selector(liveSession:errorCode:)]) {
            [self.delegate liveSession:self errorCode:errorCode];
        }
    });
}

- (void)socketDebug:(nullable id<LFStreamSocket>)socket debugInfo:(nullable LFLiveDebug *)debugInfo {
    self.debugInfo = debugInfo;
    if (self.showDebugInfo) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.delegate && [self.delegate respondsToSelector:@selector(liveSession:debugInfo:)]) {
                [self.delegate liveSession:self debugInfo:debugInfo];
            }
        });
    }
}

///status assesses (if enabled) whether to dynamically adjust video bitrate and resolution based on send queue feedback.  Bitrate increases/decreases follow a 1 step forward, 2 steps back algorithm
#define VIDEO_BITRATE_INCR_STEP 100 * 1000
#define VIDEO_BITRATE_DECR_STEP -2*VIDEO_BITRATE_INCR_STEP
- (void)socketBufferStatus:(nullable id<LFStreamSocket>)socket status:(LFLiveBuffferState)status {
    if((self.captureType & LFLiveCaptureMaskVideo || self.captureType & LFLiveInputMaskVideo) && self.adaptiveBitrate){
//        fprintf(stdout,"[LFLiveSession/socketBufferStatus:status:]...\n");
        
        NSUInteger currentVideoBitRate = _videoConfiguration.videoBitRate;
        static int timesInARowAtMinOrMaxBitrate = 0;
        
        if (status == LFLiveBuffferDecline) {
            //frame queue length is decreasing or zero, so we can up video bit rate
            //increase linearly, not geometrically
            if (currentVideoBitRate < _videoConfiguration.videoMaxBitRate) {
                _videoConfiguration.videoBitRate = MIN(currentVideoBitRate + VIDEO_BITRATE_INCR_STEP, _videoConfiguration.videoMaxBitRate);
                //DO NOT adjust encoder video bitrate here!
                fprintf(stdout,"[LFLiveSession/socketBufferStatus:status:]...increasing video bitrate from %d to %d\n",(int)currentVideoBitRate,(int)_videoConfiguration.videoBitRate);
                timesInARowAtMinOrMaxBitrate = 0;
            }
            else if (self.adaptiveResolution && timesInARowAtMinOrMaxBitrate > 1) {   //logic ==> if timesInRowAtMinOrMax is 2, then we've been there 3 times
                fprintf(stdout,"..at max bitrate for 3 times in a row, checking whether to increase resolution...\n");
                //at max bitrate for current resolution for 3 times in a row
                
                if (_videoConfiguration != _videoConfigurationHigh) {
                    LFLiveVideoConfiguration *newVidConfig = nil;
                    if (_videoConfiguration == _videoConfigurationLow) {
                        //low => medium
                        newVidConfig = _videoConfigurationMedium;
                    }
                    else {
                        //medium => high
                        newVidConfig = _videoConfigurationHigh;
                    }
                
                    fprintf(stdout,"..increasing video resolution to %dx%d\n",(int)newVidConfig.videoSize.width,(int)newVidConfig.videoSize.height);
                    
                    //start new higher resolution configuration at current configuration bitrate
                    newVidConfig.videoBitRate = _videoConfiguration.videoBitRate;
                    
                    //reset times at max counter
                    timesInARowAtMinOrMaxBitrate = 0;
                    
                    //update LFVideoCapture instance configuration
                    //note: changing video configuration propagates changes to OpenGL renderer, but there are still frames in the renderer and in the encoder
                    [self.videoCaptureSource setNewVideoConfiguration: newVidConfig];
                    
                    //update our own and track previous
                    _previousVideoConfiguration = _videoConfiguration;
                    _videoConfiguration = newVidConfig;
                }
                //else ==> nothing to do since already high
            }
            else {
                //at max bitrate for current resolution
                timesInARowAtMinOrMaxBitrate++;
            }
        }
        else {
            //status == LFLiveBufferIncrease
            //frame queue length is increasing, so we need to lower video bit rate
            //decrease linearly, not geometrically, but take 2 steps back
            if (currentVideoBitRate > _videoConfiguration.videoMinBitRate) {
                _videoConfiguration.videoBitRate = MAX(currentVideoBitRate + VIDEO_BITRATE_DECR_STEP, _videoConfiguration.videoMinBitRate);
                //DO NOT adjust encoder video bitrate here!
                fprintf(stdout,"[LFLiveSession/socketBufferStatus:status:]...decreasing video bitrate from %d to %d\n",(int)currentVideoBitRate,(int)_videoConfiguration.videoBitRate);
                timesInARowAtMinOrMaxBitrate = 0;
            }
            else if (self.adaptiveResolution && timesInARowAtMinOrMaxBitrate > 1) {   //logic ==> if timesInRowAtMinOrMax is 2, then we've been there 3 times
                fprintf(stdout,"..at max bitrate for 3 times in a row, checking whether to decrease resolution...\n");
                //at min bitrate for current resolution for 3 times in a row
                
                if (_videoConfiguration != _videoConfigurationLow) {
                    LFLiveVideoConfiguration *newVidConfig = nil;
                    if (_videoConfiguration == _videoConfigurationHigh) {
                        //high => medium
                        newVidConfig = _videoConfigurationMedium;
                    }
                    else {
                        //medium => low
                        newVidConfig = _videoConfigurationLow;
                    }
                    
                    fprintf(stdout,"..decreasing video resolution to %dx%d\n",(int)newVidConfig.videoSize.width,(int)newVidConfig.videoSize.height);
                    
                    //start new higher resolution configuration at current configuration bitrate
                    newVidConfig.videoBitRate = _videoConfiguration.videoBitRate;
                    
                    //reset times at max counter
                    timesInARowAtMinOrMaxBitrate = 0;
                    
                    //update LFVideoCapture instance configuration
                    //note: changing video configuration propagates changes to OpenGL renderer, but there are still frames in the renderer and in the encoder
                    [self.videoCaptureSource setNewVideoConfiguration: newVidConfig];
                    
                    //update our own and track previous
                    _previousVideoConfiguration = _videoConfiguration;
                    _videoConfiguration = newVidConfig;
                }
                //else ==> nothing to do since already low
            }
            else {
                //at minimum bit rate for current resolution
                timesInARowAtMinOrMaxBitrate++;
            }
        }
    }
}


//-----------------------------------------------------------------------------------------------------
#pragma mark - video configurations by resolution
-(void)createVideoConfigurationsAtResolution1 {
    _videoConfigurationLow = [LFLiveVideoConfiguration defaultConfigurationForQuality: LFLiveVideoQuality_Low1 outputImageOrientation: UIInterfaceOrientationLandscapeRight];
    _videoConfigurationMedium = [LFLiveVideoConfiguration defaultConfigurationForQuality: LFLiveVideoQuality_Medium1 outputImageOrientation: UIInterfaceOrientationLandscapeRight];
    _videoConfigurationHigh = [LFLiveVideoConfiguration defaultConfigurationForQuality: LFLiveVideoQuality_High1 outputImageOrientation: UIInterfaceOrientationLandscapeRight];
}

-(void)createVideoConfigurationsAtResolution2 {
    _videoConfigurationLow = [LFLiveVideoConfiguration defaultConfigurationForQuality: LFLiveVideoQuality_Low2 outputImageOrientation: UIInterfaceOrientationLandscapeRight];
    _videoConfigurationMedium = [LFLiveVideoConfiguration defaultConfigurationForQuality: LFLiveVideoQuality_Medium2 outputImageOrientation: UIInterfaceOrientationLandscapeRight];
    _videoConfigurationHigh = [LFLiveVideoConfiguration defaultConfigurationForQuality: LFLiveVideoQuality_High2 outputImageOrientation: UIInterfaceOrientationLandscapeRight];
}

-(void)createVideoConfigurationsAtResolution3 {
    _videoConfigurationLow = [LFLiveVideoConfiguration defaultConfigurationForQuality: LFLiveVideoQuality_Low3 outputImageOrientation: UIInterfaceOrientationLandscapeRight];
    _videoConfigurationMedium = [LFLiveVideoConfiguration defaultConfigurationForQuality: LFLiveVideoQuality_Medium3 outputImageOrientation: UIInterfaceOrientationLandscapeRight];
    _videoConfigurationHigh = [LFLiveVideoConfiguration defaultConfigurationForQuality: LFLiveVideoQuality_High3 outputImageOrientation: UIInterfaceOrientationLandscapeRight];
}


//-----------------------------------------------------------------------------------------------------
#pragma mark -- Getter Setter
- (void)setRunning:(BOOL)running {
    if (_running == running) return;
    [self willChangeValueForKey:@"running"];
    _running = running;
    [self didChangeValueForKey:@"running"];
    self.videoCaptureSource.running = _running;
    self.audioCaptureSource.running = _running;
}

- (void)setPreView:(UIView *)preView {
    [self willChangeValueForKey:@"preView"];
    [self.videoCaptureSource setPreView:preView];
    [self didChangeValueForKey:@"preView"];
}

- (UIView *)preView {
    return self.videoCaptureSource.preView;
}

- (void)setCaptureDevicePosition:(AVCaptureDevicePosition)captureDevicePosition {
    [self willChangeValueForKey:@"captureDevicePosition"];
    [self.videoCaptureSource setCaptureDevicePosition:captureDevicePosition];
    [self didChangeValueForKey:@"captureDevicePosition"];
}

- (AVCaptureDevicePosition)captureDevicePosition {
    return self.videoCaptureSource.captureDevicePosition;
}

- (void)setBeautyFace:(BOOL)beautyFace {
    [self willChangeValueForKey:@"beautyFace"];
    [self.videoCaptureSource setBeautyFace:beautyFace];
    [self didChangeValueForKey:@"beautyFace"];
}

- (BOOL)saveLocalVideo{
    return self.videoCaptureSource.saveLocalVideo;
}

- (void)setSaveLocalVideo:(BOOL)saveLocalVideo{
    [self.videoCaptureSource setSaveLocalVideo:saveLocalVideo];
}


- (NSURL*)saveLocalVideoPath{
    return self.videoCaptureSource.saveLocalVideoPath;
}

- (void)setSaveLocalVideoPath:(NSURL*)saveLocalVideoPath{
    [self.videoCaptureSource setSaveLocalVideoPath:saveLocalVideoPath];
}

- (BOOL)beautyFace {
    return self.videoCaptureSource.beautyFace;
}

- (void)setBeautyLevel:(CGFloat)beautyLevel {
    [self willChangeValueForKey:@"beautyLevel"];
    [self.videoCaptureSource setBeautyLevel:beautyLevel];
    [self didChangeValueForKey:@"beautyLevel"];
}

- (CGFloat)beautyLevel {
    return self.videoCaptureSource.beautyLevel;
}

- (void)setBrightLevel:(CGFloat)brightLevel {
    [self willChangeValueForKey:@"brightLevel"];
    [self.videoCaptureSource setBrightLevel:brightLevel];
    [self didChangeValueForKey:@"brightLevel"];
}

- (CGFloat)brightLevel {
    return self.videoCaptureSource.brightLevel;
}

- (void)setZoomScale:(CGFloat)zoomScale {
    [self willChangeValueForKey:@"zoomScale"];
    [self.videoCaptureSource setZoomScale:zoomScale];
    [self didChangeValueForKey:@"zoomScale"];
}

- (CGFloat)zoomScale {
    return self.videoCaptureSource.zoomScale;
}

- (void)setTorch:(BOOL)torch {
    [self willChangeValueForKey:@"torch"];
    [self.videoCaptureSource setTorch:torch];
    [self didChangeValueForKey:@"torch"];
}

- (BOOL)torch {
    return self.videoCaptureSource.torch;
}

- (void)setMirror:(BOOL)mirror {
    [self willChangeValueForKey:@"mirror"];
    [self.videoCaptureSource setMirror:mirror];
    [self didChangeValueForKey:@"mirror"];
}

- (BOOL)mirror {
    return self.videoCaptureSource.mirror;
}

- (void)setMuted:(BOOL)muted {
    [self willChangeValueForKey:@"muted"];
    [self.audioCaptureSource setMuted:muted];
    [self didChangeValueForKey:@"muted"];
}

- (BOOL)muted {
    return self.audioCaptureSource.muted;
}

- (void)setWatermarkView:(UIView *)watermarkView{
    [self.videoCaptureSource setWatermarkView:watermarkView];
}

- (nullable UIView*)watermarkView{
    return self.videoCaptureSource.watermarkView;
}

- (nullable UIImage *)currentImage{
    return self.videoCaptureSource.currentImage;
}

- (LFAudioCapture *)audioCaptureSource {
    if (!_audioCaptureSource) {
        if(self.captureType & LFLiveCaptureMaskAudio){
            _audioCaptureSource = [[LFAudioCapture alloc] initWithAudioConfiguration:_audioConfiguration];
            _audioCaptureSource.delegate = self;
        }
    }
    return _audioCaptureSource;
}

- (LFVideoCapture *)videoCaptureSource {
    if (!_videoCaptureSource) {
        if(self.captureType & LFLiveCaptureMaskVideo){
            _videoCaptureSource = [[LFVideoCapture alloc] initWithVideoConfiguration:_videoConfiguration capturePreviewVideoOrientation:_capturePreviewVideoOrientation];
            _videoCaptureSource.delegate = self;
        }
    }
    return _videoCaptureSource;
}

- (id<LFAudioEncoding>)audioEncoder {
    if (!_audioEncoder) {
        _audioEncoder = [[LFHardwareAudioEncoder alloc] initWithAudioStreamConfiguration:_audioConfiguration];
        [_audioEncoder setDelegate:self];
    }
    return _audioEncoder;
}

//- (id<LFVideoEncoding>)videoEncoder {
//    if (!_videoEncoder) {
//        //note: we the videoEncoder's configuration to be encapsulated, so provide it a copy
//        if([[UIDevice currentDevice].systemVersion floatValue] < 8.0){
//            _videoEncoder = [[LFH264VideoEncoder alloc] initWithVideoStreamConfiguration:[_videoConfiguration copy]];
//        } else {
//            _videoEncoder = [[LFHardwareVideoEncoder alloc] initWithVideoStreamConfiguration:[_videoConfiguration copy]];
//        }
//        [_videoEncoder setDelegate:self];
//    }
//    return _videoEncoder;
//}

-(id<LFVideoEncoding>)videoEncoderLow {
    if (!_videoEncoderLow) {
        assert([[UIDevice currentDevice].systemVersion floatValue] >= 8.0);
        _videoEncoderLow = [[LFHardwareVideoEncoder alloc] initWithVideoStreamConfiguration: _videoConfigurationLow];
        [_videoEncoderLow setDelegate:self];
    }
    return _videoEncoderLow;
}

-(id<LFVideoEncoding>)videoEncoderMedium {
    if (!_videoEncoderMedium) {
        assert([[UIDevice currentDevice].systemVersion floatValue] >= 8.0);
        _videoEncoderMedium = [[LFHardwareVideoEncoder alloc] initWithVideoStreamConfiguration: _videoConfigurationMedium];
        [_videoEncoderMedium setDelegate:self];
    }
    return _videoEncoderMedium;
}

-(id<LFVideoEncoding>)videoEncoderHigh {
    if (!_videoEncoderHigh) {
        assert([[UIDevice currentDevice].systemVersion floatValue] >= 8.0);
        _videoEncoderHigh = [[LFHardwareVideoEncoder alloc] initWithVideoStreamConfiguration: _videoConfigurationHigh];
        [_videoEncoderHigh setDelegate:self];
    }
    return _videoEncoderHigh;
}

- (id<LFStreamSocket>)socket {
    if (!_socket) {
        _socket = [[LFStreamRTMPSocket alloc] initWithStream:self.streamInfo reconnectInterval:self.reconnectInterval reconnectCount:self.reconnectCount disableRetry:self.disableRetry];
        [_socket setDelegate:self];
    }
    return _socket;
}

- (LFLiveStreamInfo *)streamInfo {
    if (!_streamInfo) {
        _streamInfo = [[LFLiveStreamInfo alloc] init];
    }
    return _streamInfo;
}

- (dispatch_semaphore_t)lock{
    if(!_lock){
        _lock = dispatch_semaphore_create(1);
    }
    return _lock;
}

- (uint64_t)uploadTimestamp:(uint64_t)captureTimestamp{
    dispatch_semaphore_wait(self.lock, DISPATCH_TIME_FOREVER);
    uint64_t currentts = 0;
    currentts = captureTimestamp - self.relativeTimestamps;
    dispatch_semaphore_signal(self.lock);
    return currentts;
}

- (BOOL)AVAlignment{
    if((self.captureType & LFLiveCaptureMaskAudio || self.captureType & LFLiveInputMaskAudio) &&
       (self.captureType & LFLiveCaptureMaskVideo || self.captureType & LFLiveInputMaskVideo)) {
        if(self.hasCaptureAudio && self.hasKeyFrameVideo)
            return YES;
        else
            return NO;
    }else{
        return YES;
    }
}

@end
