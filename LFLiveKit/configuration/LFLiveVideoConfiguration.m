//
//  LFLiveVideoConfiguration.m
//  LFLiveKit
//
//  Created by LaiFeng on 16/5/20.
//  Copyright © 2016年 LaiFeng All rights reserved.
//

#import "LFLiveVideoConfiguration.h"
#import <AVFoundation/AVFoundation.h>


@implementation LFLiveVideoConfiguration




/*  According to several sources:
    -0.1 bits/pixel is considered very good quality
    -0.03 bits/pixel is considered very poor quality
 
    as an example, ESPN encodes high-motion sports at 0.203 bits/pixel
 
 To compute bitrate, multiply bits/pixel * pixels/sec = bits/sec
 ie bits/sec = pixels/frame * frames/sec * bits/pixel
 */



#pragma mark -- LifeCycle
+ (instancetype)defaultConfiguration {
    LFLiveVideoConfiguration *configuration = [LFLiveVideoConfiguration defaultConfigurationForQuality:LFLiveVideoQuality_Default];
    return configuration;
}

+ (instancetype)defaultConfigurationForQuality:(LFLiveVideoQuality)videoQuality {
    LFLiveVideoConfiguration *configuration = [LFLiveVideoConfiguration defaultConfigurationForQuality:videoQuality outputImageOrientation:UIInterfaceOrientationPortrait];
    return configuration;
}

+ (instancetype)defaultConfigurationForQuality:(LFLiveVideoQuality)videoQuality outputImageOrientation:(UIInterfaceOrientation)outputImageOrientation {
    LFLiveVideoConfiguration *configuration = [LFLiveVideoConfiguration new];
    configuration.outputImageOrientation = outputImageOrientation;
    [configuration updateConfigurationBasedOnVideoQuality:videoQuality];
    
    return configuration;
}


//-----------------------------------------------------------------------------------------------------
#pragma mark - derive from videoQuality
- (void)updateConfigurationBasedOnVideoQuality:(LFLiveVideoQuality)videoQuality {
    //set desired sessionPreset and set videoFrameRate which won't change even if sessionPreset must be lowered because desired resolution isn't supported
    switch (videoQuality) {
        case LFLiveVideoQuality_Low1:
            _sessionPreset = LFCaptureSessionPreset360x640;
            _videoFrameRate = 15;
            break;
        case LFLiveVideoQuality_Low2:
            _sessionPreset = LFCaptureSessionPreset360x640;
            _videoFrameRate = 24;
            break;
        case LFLiveVideoQuality_Low3:
            _sessionPreset = LFCaptureSessionPreset360x640;
            _videoFrameRate = 30;
            break;
        case LFLiveVideoQuality_Medium1:
            _sessionPreset = LFCaptureSessionPreset540x960;
            _videoFrameRate = 15;
            break;
        case LFLiveVideoQuality_Medium2:
            _sessionPreset = LFCaptureSessionPreset540x960;
            _videoFrameRate = 24;
            break;
        case LFLiveVideoQuality_Medium3:
            _sessionPreset = LFCaptureSessionPreset540x960;
            _videoFrameRate = 30;
            break;
        case LFLiveVideoQuality_High1:
            _sessionPreset = LFCaptureSessionPreset720x1280;
            _videoFrameRate = 15;
            break;
        case LFLiveVideoQuality_High2:
            _sessionPreset = LFCaptureSessionPreset720x1280;
            _videoFrameRate = 24;
            break;
        case LFLiveVideoQuality_High3:
            _sessionPreset = LFCaptureSessionPreset720x1280;
            _videoFrameRate = 30;
            break;
        default:
            break;
    }
    
    //check if sessionPreset is supported on front facing camera, and if not, configure to next highest/closest supported
    //why base on front canera? because it is less capable compared to rear camera (ie max front facing res is surely available on rear facing cam) and I guess  we don't want to support different resolutions when switching because to do so would require carefully managing video bitrate
    LFLiveVideoSessionPreset supportedSessionPreset = [self supportSessionPreset: self.sessionPreset];
    if (supportedSessionPreset != _sessionPreset) {
        _sessionPreset = supportedSessionPreset;
        //adjust videoQuality for actual sessionPreset
        switch (_sessionPreset) {
            case LFCaptureSessionPreset360x640:
                if (_videoFrameRate == 15)
                    _videoQuality = LFLiveVideoQuality_Low1;
                else if (_videoFrameRate == 24)
                    _videoQuality = LFLiveVideoQuality_Low2;
                else
                    _videoQuality = LFLiveVideoQuality_Low3;
                break;
            case LFCaptureSessionPreset540x960:
                if (_videoFrameRate == 15)
                    _videoQuality = LFLiveVideoQuality_Medium1;
                else if (_videoFrameRate == 24)
                    _videoQuality = LFLiveVideoQuality_Medium2;
                else
                    _videoQuality = LFLiveVideoQuality_Medium3;
                break;
            case LFCaptureSessionPreset720x1280:
                if (_videoFrameRate == 15)
                    _videoQuality = LFLiveVideoQuality_High1;
                else if (_videoFrameRate == 24)
                    _videoQuality = LFLiveVideoQuality_High2;
                else
                    _videoQuality = LFLiveVideoQuality_High3;
                break;
            default:
                break;
        }
    }
    else {
        _videoQuality = videoQuality;
    }
    
    //compute video size based on supported session preset (method also takes into account whether landscape)
    _videoSize = [self captureOutVideoSize];
    
    //set limits on key frame interval; both max frame interval and max interval duration will be enforced
    //both but we can also set either to 0 to let encoder decide
    //several sources concur that max key frame interval is twice frame rate
    _videoMaxKeyframeInterval = 0;      //self.videoFrameRate*2;
    _videoMaxKeyframeIntervalDuration = 0;
    
    //set bitrates (which are size and frame rate dependent)
    //bits/pixel for poorest quality (min) and highest quality (max)
    double bitsPerPixelMin, bitsPerPixelMax;
    
    switch (_sessionPreset) {
        case LFCaptureSessionPreset360x640:
            //at 0.1 bits/pixel, min bitrate is 691200 kbps at 360p
            bitsPerPixelMin = 0.1;
            //at 0.21 bits/pixel, max bitrate is 1451520 kbps at 360p
            bitsPerPixelMax = 0.21;
            break;
        case LFCaptureSessionPreset540x960:
            //at 0.07 bits/pixel, min bitrate is 1088640 kbps at 540p
            bitsPerPixelMin = 0.07;
            //at 0.19 bits/pixel, max bitrate is 2799360 kbps at 540p
            bitsPerPixelMax = 0.18;
            break;
        case LFCaptureSessionPreset720x1280:
            //at 0.04 bits/pixel, min bitrate is 1105920 kbps at 720p
            bitsPerPixelMin = 0.04;
            //at 0.14 bits/pixel, max bitrate is 3870720 kbps at 720p
            bitsPerPixelMax = 0.14;
            break;
        default:
            break;
    }
    
    double pixelsPerSec = (double)((NSUInteger)self.videoSize.width * (NSUInteger)self.videoSize.height * self.videoFrameRate);
    _videoMinBitRate = (NSUInteger)ceil(bitsPerPixelMin * pixelsPerSec);
    _videoMaxBitRate = (NSUInteger)floor(bitsPerPixelMax * pixelsPerSec);
    _videoBitRate = _videoMinBitRate; //start at 0.1  //(NSUInteger)ceil((double)(_videoMinBitRate + _videoMaxBitRate) / 2.0);
}


//-----------------------------------------------------------------------------------------------------
#pragma mark -- Setter Getter
- (NSString *)avSessionPreset {
    NSString *avSessionPreset = nil;
    switch (self.sessionPreset) {
    case LFCaptureSessionPreset360x640:{
        avSessionPreset = AVCaptureSessionPreset640x480;
    }
        break;
    case LFCaptureSessionPreset540x960:{
        avSessionPreset = AVCaptureSessionPresetiFrame960x540;
    }
        break;
    case LFCaptureSessionPreset720x1280:{
        avSessionPreset = AVCaptureSessionPreset1280x720;
    }
        break;
    default: {
        avSessionPreset = AVCaptureSessionPreset640x480;
    }
        break;
    }
    return avSessionPreset;
}

- (BOOL)landscape{
    return (self.outputImageOrientation == UIInterfaceOrientationLandscapeLeft || self.outputImageOrientation == UIInterfaceOrientationLandscapeRight) ? YES : NO;
}

- (CGSize)videoSize{
    if(_videoSizeRespectingAspectRatio){
        return self.aspectRatioVideoSize;
    }
    return _videoSize;
}

-(void)setVideoBitRate:(NSUInteger)videoBitRate {
    if (videoBitRate > _videoMaxBitRate) {
        _videoBitRate = _videoMaxBitRate;
    }
    else if (videoBitRate < _videoMinBitRate) {
        _videoBitRate = _videoMinBitRate;
    }
    else {
        _videoBitRate = videoBitRate;
    }
}

-(void)setVideoQuality:(LFLiveVideoQuality)videoQuality {
    [self updateConfigurationBasedOnVideoQuality:videoQuality];
}

//- (void)setVideoMaxBitRate:(NSUInteger)videoMaxBitRate {
//    if (videoMaxBitRate <= _videoBitRate) return;
//    _videoMaxBitRate = videoMaxBitRate;
//}
//
//- (void)setVideoMinBitRate:(NSUInteger)videoMinBitRate {
//    if (videoMinBitRate >= _videoBitRate) return;
//    _videoMinBitRate = videoMinBitRate;
//}

//- (void)setVideoMaxFrameRate:(NSUInteger)videoMaxFrameRate {
//    if (videoMaxFrameRate <= _videoFrameRate) return;
//    _videoMaxFrameRate = videoMaxFrameRate;
//}

//- (void)setVideoMinFrameRate:(NSUInteger)videoMinFrameRate {
//    if (videoMinFrameRate >= _videoFrameRate) return;
//    _videoMinFrameRate = videoMinFrameRate;
//}

//UGH: this setter exposes an inconsistency: preset needs to correlate with videoSize and video bitrates, but implementation of this setter does neither
//- (void)setSessionPreset:(LFLiveVideoSessionPreset)sessionPreset{
//    _sessionPreset = sessionPreset;
//    _sessionPreset = [self supportSessionPreset:sessionPreset];
//}


//-----------------------------------------------------------------------------------------------------
#pragma mark - utilities
- (LFLiveVideoSessionPreset)supportSessionPreset:(LFLiveVideoSessionPreset)sessionPreset {
    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    AVCaptureDevice *inputCamera;
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    for (AVCaptureDevice *device in devices){
        if ([device position] == AVCaptureDevicePositionFront){
            inputCamera = device;
        }
    }
    AVCaptureDeviceInput *videoInput = [[AVCaptureDeviceInput alloc] initWithDevice:inputCamera error:nil];
    
    if ([session canAddInput:videoInput]){
        [session addInput:videoInput];
    }
    
    if (![session canSetSessionPreset:self.avSessionPreset]) {
        if (sessionPreset == LFCaptureSessionPreset720x1280) {
            sessionPreset = LFCaptureSessionPreset540x960;
            if (![session canSetSessionPreset:self.avSessionPreset]) {
                sessionPreset = LFCaptureSessionPreset360x640;
            }
        } else if (sessionPreset == LFCaptureSessionPreset540x960) {
            sessionPreset = LFCaptureSessionPreset360x640;
        }
    }
    return sessionPreset;
}

- (CGSize)captureOutVideoSize{
    CGSize videoSize = CGSizeZero;
    switch (_sessionPreset) {
        case LFCaptureSessionPreset360x640:{
            videoSize = CGSizeMake(360, 640);
        }
            break;
        case LFCaptureSessionPreset540x960:{
            videoSize = CGSizeMake(540, 960);
        }
            break;
        case LFCaptureSessionPreset720x1280:{
            videoSize = CGSizeMake(720, 1280);
        }
            break;
            
        default:{
            videoSize = CGSizeMake(360, 640);
        }
            break;
    }
    
    if (self.landscape){
        return CGSizeMake(videoSize.height, videoSize.width);
    }
    return videoSize;
}

- (CGSize)aspectRatioVideoSize{
    CGSize size = AVMakeRectWithAspectRatioInsideRect(self.captureOutVideoSize, CGRectMake(0, 0, _videoSize.width, _videoSize.height)).size;
    NSInteger width = ceil(size.width);
    NSInteger height = ceil(size.height);
    if(width %2 != 0) width = width - 1;
    if(height %2 != 0) height = height - 1;
    return CGSizeMake(width, height);
}


//-----------------------------------------------------------------------------------------------------
#pragma mark - encoder
- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:[NSValue valueWithCGSize:self.videoSize] forKey:@"videoSize"];
    [aCoder encodeObject:@(self.videoFrameRate) forKey:@"videoFrameRate"];
//    [aCoder encodeObject:@(self.videoMaxFrameRate) forKey:@"videoMaxFrameRate"];
//    [aCoder encodeObject:@(self.videoMinFrameRate) forKey:@"videoMinFrameRate"];
    [aCoder encodeObject:@(self.videoMaxKeyframeInterval) forKey:@"videoMaxKeyframeInterval"];
    [aCoder encodeObject:@(self.videoBitRate) forKey:@"videoBitRate"];
    [aCoder encodeObject:@(self.videoMaxBitRate) forKey:@"videoMaxBitRate"];
    [aCoder encodeObject:@(self.videoMinBitRate) forKey:@"videoMinBitRate"];
    [aCoder encodeObject:@(self.sessionPreset) forKey:@"sessionPreset"];
    [aCoder encodeObject:@(self.outputImageOrientation) forKey:@"outputImageOrientation"];
    [aCoder encodeObject:@(self.autorotate) forKey:@"autorotate"];
    [aCoder encodeObject:@(self.videoSizeRespectingAspectRatio) forKey:@"videoSizeRespectingAspectRatio"];
}

- (id)initWithCoder:(NSCoder *)aDecoder {
    self = [super init];
    _videoSize = [[aDecoder decodeObjectForKey:@"videoSize"] CGSizeValue];
    _videoFrameRate = [[aDecoder decodeObjectForKey:@"videoFrameRate"] unsignedIntegerValue];
//    _videoMaxFrameRate = [[aDecoder decodeObjectForKey:@"videoMaxFrameRate"] unsignedIntegerValue];
//    _videoMinFrameRate = [[aDecoder decodeObjectForKey:@"videoMinFrameRate"] unsignedIntegerValue];
    _videoMaxKeyframeInterval = [[aDecoder decodeObjectForKey:@"videoMaxKeyframeInterval"] unsignedIntegerValue];
    _videoBitRate = [[aDecoder decodeObjectForKey:@"videoBitRate"] unsignedIntegerValue];
    _videoMaxBitRate = [[aDecoder decodeObjectForKey:@"videoMaxBitRate"] unsignedIntegerValue];
    _videoMinBitRate = [[aDecoder decodeObjectForKey:@"videoMinBitRate"] unsignedIntegerValue];
    _sessionPreset = [[aDecoder decodeObjectForKey:@"sessionPreset"] unsignedIntegerValue];
    _outputImageOrientation = [[aDecoder decodeObjectForKey:@"outputImageOrientation"] unsignedIntegerValue];
    _autorotate = [[aDecoder decodeObjectForKey:@"autorotate"] boolValue];
    _videoSizeRespectingAspectRatio = [[aDecoder decodeObjectForKey:@"videoSizeRespectingAspectRatio"] unsignedIntegerValue];
    return self;
}

- (NSUInteger)hash {
    NSUInteger hash = 0;
    NSArray *values = @[[NSValue valueWithCGSize:self.videoSize],
                        @(self.videoFrameRate),
//                        @(self.videoMaxFrameRate),
//                        @(self.videoMinFrameRate),
                        @(self.videoMaxKeyframeInterval),
                        @(self.videoBitRate),
                        @(self.videoMaxBitRate),
                        @(self.videoMinBitRate),
                        self.avSessionPreset,
                        @(self.sessionPreset),
                        @(self.outputImageOrientation),
                        @(self.autorotate),
                        @(self.videoSizeRespectingAspectRatio)];

    for (NSObject *value in values) {
        hash ^= value.hash;
    }
    return hash;
}


//-----------------------------------------------------------------------------------------------------
#pragma mark - equality
- (BOOL)isEqual:(id)other {
    if (other == self) {
        return YES;
    } else if (![super isEqual:other]) {
        return NO;
    } else {
        LFLiveVideoConfiguration *object = other;
        return CGSizeEqualToSize(object.videoSize, self.videoSize) &&
               object.videoFrameRate == self.videoFrameRate &&
//               object.videoMaxFrameRate == self.videoMaxFrameRate &&
//               object.videoMinFrameRate == self.videoMinFrameRate &&
               object.videoMaxKeyframeInterval == self.videoMaxKeyframeInterval &&
               object.videoBitRate == self.videoBitRate &&
               object.videoMaxBitRate == self.videoMaxBitRate &&
               object.videoMinBitRate == self.videoMinBitRate &&
               [object.avSessionPreset isEqualToString:self.avSessionPreset] &&
               object.sessionPreset == self.sessionPreset &&
               object.outputImageOrientation == self.outputImageOrientation &&
               object.autorotate == self.autorotate &&
               object.videoSizeRespectingAspectRatio == self.videoSizeRespectingAspectRatio;
    }
}


//-----------------------------------------------------------------------------------------------------
#pragma mark - NSCopying
- (id)copyWithZone:(nullable NSZone *)zone {
    LFLiveVideoConfiguration *other = [self.class defaultConfigurationForQuality: _videoQuality outputImageOrientation: _outputImageOrientation];
    other.videoSize = _videoSize;
    other.videoSizeRespectingAspectRatio = _videoSizeRespectingAspectRatio;
    other.outputImageOrientation = _outputImageOrientation;
    other.autorotate = _autorotate;
    //other.videoFrameRate = _videoFrameRate;
//    other.videoMaxKeyframeInterval = _videoMaxKeyframeInterval;
    other.videoBitRate = _videoBitRate;
    //other.videoMinBitRate = _videoMinBitRate;
    //other.videoMinBitRate = _videoMaxBitRate;
    //other.sessionPreset = _sessionPreset;
    //avSessionPreset is a computed property
    //other.landscape = _landscape;
    return other;
}


//-----------------------------------------------------------------------------------------------------
#pragma mark - description
- (NSString *)description {
    NSMutableString *desc = @"".mutableCopy;
    [desc appendFormat:@"<LFLiveVideoConfiguration: %p>", self];
    [desc appendFormat:@" videoSize:%@", NSStringFromCGSize(self.videoSize)];
    [desc appendFormat:@" videoSizeRespectingAspectRatio:%zi",self.videoSizeRespectingAspectRatio];
    [desc appendFormat:@" videoFrameRate:%zi", self.videoFrameRate];
//    [desc appendFormat:@" videoMaxFrameRate:%zi", self.videoMaxFrameRate];
//    [desc appendFormat:@" videoMinFrameRate:%zi", self.videoMinFrameRate];
    [desc appendFormat:@" videoMaxKeyframeInterval:%zi", self.videoMaxKeyframeInterval];
    [desc appendFormat:@" videoBitRate:%zi", self.videoBitRate];
    [desc appendFormat:@" videoMaxBitRate:%zi", self.videoMaxBitRate];
    [desc appendFormat:@" videoMinBitRate:%zi", self.videoMinBitRate];
    [desc appendFormat:@" avSessionPreset:%@", self.avSessionPreset];
    [desc appendFormat:@" sessionPreset:%zi", self.sessionPreset];
    [desc appendFormat:@" outputImageOrientation:%zi", self.outputImageOrientation];
    [desc appendFormat:@" autorotate:%zi", self.autorotate];
    return desc;
}


//-----------------------------------------------------------------------------------------------------
#pragma mark - ?
- (void)refreshVideoSize {
    CGSize size = self.videoSize;
    if(self.landscape) {
        CGFloat width = MAX(size.width, size.height);
        CGFloat height = MIN(size.width, size.height);
        self.videoSize = CGSizeMake(width, height);
    } else {
        CGFloat width = MIN(size.width, size.height);
        CGFloat height = MAX(size.width, size.height);
        self.videoSize = CGSizeMake(width, height);
    }
}

@end
