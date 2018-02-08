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
@property(nonatomic,strong) id<LFVideoEncoding> videoEncoderLow;
@property(nonatomic,strong) id<LFVideoEncoding> videoEncoderMedium;
@property(nonatomic,strong) id<LFVideoEncoding> videoEncoderHigh;
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

- (nullable instancetype)initWithAudioConfiguration:(nullable LFLiveAudioConfiguration *)audioConfiguration videoConfiguration:(nullable LFLiveVideoConfiguration *)videoConfiguration captureType:(LFLiveCaptureTypeMask)captureType{
    if((captureType & LFLiveCaptureMaskAudio || captureType & LFLiveInputMaskAudio) && !audioConfiguration) @throw [NSException exceptionWithName:@"LFLiveSession init error" reason:@"audioConfiguration is nil " userInfo:nil];
    if((captureType & LFLiveCaptureMaskVideo || captureType & LFLiveInputMaskVideo) && !videoConfiguration) @throw [NSException exceptionWithName:@"LFLiveSession init error" reason:@"videoConfiguration is nil " userInfo:nil];
    if (self = [super init]) {
        _audioConfiguration = audioConfiguration;
        
        //since we do not allow changing frame rate midstream, create low, med, high video configurations based on target frame rate (reflected by 1, 2, or 3)
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
        
        _previousVideoConfiguration = nil;
        _adaptiveBitrate = NO;
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

#pragma mark -- CustomMethod
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
//frame encoding callbacks
#pragma mark -- PrivateMethod
- (void)pushSendBuffer:(LFFrame*)frame{
    if(self.relativeTimestamps == 0){
        self.relativeTimestamps = frame.timestamp;
    }
    
    frame.timestamp = [self uploadTimestamp:frame.timestamp];
//    fprintf(stdout,"[LFLiveSession/pushSendBuffer:]...frame.timestamp=%llu\n",frame.timestamp);
    
    [self.socket sendFrame:frame];
}


//-----------------------------------------------------------------------------------------------------
//called when capture session instances have readied a new frame for encoding
#pragma mark -- CaptureDelegate
- (void)captureOutput:(nullable LFAudioCapture *)capture audioData:(nullable NSData*)audioData {
//    fprintf(stdout,"[LFLiveSession/captureOutput:audioData:}...\n");
    if (self.uploading)
        [self.audioEncoder encodeAudioData:audioData timeStamp:NOW];
}

- (void)captureOutput:(nullable LFVideoCapture *)capture pixelBuffer:(nullable CVPixelBufferRef)pixelBuffer {
    if (self.uploading) {
        //[self.videoEncoder encodeVideoData:pixelBuffer timeStamp:NOW];
        [self encodePixelBuffer: pixelBuffer timeStamp: NOW];
    }
}


///call to target encoder appropriate to pixel buffer resolution
-(void)encodePixelBuffer:(nonnull CVPixelBufferRef)pixelBuffer timeStamp:(uint64_t)timestamp {
//    [self.videoEncoder setVideoBitRate: _videoConfiguration.videoBitRate];
//    [self.videoEncoder encodeVideoData: pixelBuffer timeStamp: timestamp];
    
    //select correct encoder based on image resolution (720p, 540p, 360p, ie based on height param only)
    int bufferHeight = (int) CVPixelBufferGetHeight(pixelBuffer);
    fprintf(stdout,"[LFLiveSession/encodePixelBuffer:timestamp:]...pixel buffer height=%d\n",bufferHeight);
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
    
    //if we just changed video configuration, and if this frame to be encoded is the first frame from the render pipeline with resolution matching the new configuration, then previousVideoConfiguration is set and we need to reset its corresponding video encoder so that it is ready to start on a key frame if we return to the previous resolution
    if (bufferHeight == _videoConfiguration.videoSize.height && _previousVideoConfiguration) {
        fprintf(stdout,"..resetting previous video configuration video encoder session..\n");
        switch (_previousVideoConfiguration.videoQuality) {
            case LFLiveVideoQuality_Low1:
            case LFLiveVideoQuality_Low2:
            case LFLiveVideoQuality_Low3:
                [self.videoEncoderLow resetCompressionSession];
                break;
            case LFLiveVideoQuality_Medium1:
            case LFLiveVideoQuality_Medium2:
            case LFLiveVideoQuality_Medium3:
                [self.videoEncoderMedium resetCompressionSession];
                break;
            case LFLiveVideoQuality_High1:
            case LFLiveVideoQuality_High2:
            case LFLiveVideoQuality_High3:
                [self.videoEncoderHigh resetCompressionSession];
                break;
            default:
                break;
        }
        
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
            //TODO: parse frame size from sps
            [self pushSendBuffer:frame];
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

- (void)socketBufferStatus:(nullable id<LFStreamSocket>)socket status:(LFLiveBuffferState)status {
    if((self.captureType & LFLiveCaptureMaskVideo || self.captureType & LFLiveInputMaskVideo) && self.adaptiveBitrate){
//        fprintf(stdout,"[LFLiveSession/socketBufferStatus:status:]...\n");
        
        NSUInteger currentVideoBitRate = _videoConfiguration.videoBitRate;
        static int timesInARowAtMinOrMaxBitrate = 0;
        
        if (status == LFLiveBuffferDecline) {
            //frame queue length is decreasing or zdro, so we can up video bit rate
            if (currentVideoBitRate < _videoConfiguration.videoMaxBitRate) {
                _videoConfiguration.videoBitRate = MIN(currentVideoBitRate + 100 * 1000, _videoConfiguration.videoMaxBitRate);
                //DO NOT adjust encoder video bitrate here!
                fprintf(stdout,"[LFLiveSession/socketBufferStatus:status:]...increasing video bitrate from %d to %d\n",(int)currentVideoBitRate,(int)_videoConfiguration.videoBitRate);
                timesInARowAtMinOrMaxBitrate = 0;
            }
            else if (timesInARowAtMinOrMaxBitrate > 1) {   //logic ==> if timesInRowAtMinOrMax is 2, then we've been there 3 times
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
                    
                    //start higher resolution configuration at its min bitrate
                    newVidConfig.videoBitRate = newVidConfig.videoMinBitRate;
                    
                    //reset times at max counter
                    timesInARowAtMinOrMaxBitrate = 0;
                    
                    //update LFVideoCapture instance configuration
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
        } else {
            //status == LFLiveBufferIncrease
            //frame queue length is increasing, so we need to lower video bit rate
            if (currentVideoBitRate > _videoConfiguration.videoMinBitRate) {
                _videoConfiguration.videoBitRate = MAX(currentVideoBitRate - 100 * 1000, _videoConfiguration.videoMinBitRate);
                //DO NOT adjust encoder video bitrate here!
                fprintf(stdout,"[LFLiveSession/socketBufferStatus:status:]...decreasing video bitrate from %d to %d\n",(int)currentVideoBitRate,(int)_videoConfiguration.videoBitRate);
                timesInARowAtMinOrMaxBitrate = 0;
            }
            else if (timesInARowAtMinOrMaxBitrate > 1) {   //logic ==> if timesInRowAtMinOrMax is 2, then we've been there 3 times
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
                    
                    //start lower resolution configuration at its max bitrate
                    newVidConfig.videoBitRate = newVidConfig.videoMaxBitRate;
                    
                    //reset times at max counter
                    timesInARowAtMinOrMaxBitrate = 0;
                    
                    //update LFVideoCapture instance configuration
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
