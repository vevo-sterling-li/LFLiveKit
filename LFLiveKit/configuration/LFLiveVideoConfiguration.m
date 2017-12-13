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
    [configuration updateConfigurationBasedOnVideoQuality:videoQuality];
    configuration.outputImageOrientation = outputImageOrientation;

    return configuration;
}

- (void)updateConfigurationBasedOnVideoQuality:(LFLiveVideoQuality)videoQuality {
    self.videoQuality = videoQuality;
    switch (videoQuality) {
        case LFLiveVideoQuality_Low1:{
            self.sessionPreset = LFCaptureSessionPreset360x640;
            self.videoFrameRate = 15;
            self.videoMaxFrameRate = 15;
            self.videoMinFrameRate = 10;
            self.videoBitRate = 500 * 1000;
            self.videoMaxBitRate = 600 * 1000;
            self.videoMinBitRate = 400 * 1000;
            self.videoSize = CGSizeMake(360, 640);
        }
            break;
        case LFLiveVideoQuality_Low2:{
            self.sessionPreset = LFCaptureSessionPreset360x640;
            self.videoFrameRate = 24;
            self.videoMaxFrameRate = 24;
            self.videoMinFrameRate = 12;
            self.videoBitRate = 600 * 1000;
            self.videoMaxBitRate = 720 * 1000;
            self.videoMinBitRate = 500 * 1000;
            self.videoSize = CGSizeMake(360, 640);
        }
            break;
        case LFLiveVideoQuality_Low3: {
            self.sessionPreset = LFCaptureSessionPreset360x640;
            self.videoFrameRate = 30;
            self.videoMaxFrameRate = 30;
            self.videoMinFrameRate = 15;
            self.videoBitRate = 800 * 1000;
            self.videoMaxBitRate = 960 * 1000;
            self.videoMinBitRate = 600 * 1000;
            self.videoSize = CGSizeMake(360, 640);
        }
            break;
        case LFLiveVideoQuality_Medium1:{
            self.sessionPreset = LFCaptureSessionPreset540x960;
            self.videoFrameRate = 15;
            self.videoMaxFrameRate = 15;
            self.videoMinFrameRate = 10;
            self.videoBitRate = 800 * 1000;
            self.videoMaxBitRate = 960 * 1000;
            self.videoMinBitRate = 500 * 1000;
            self.videoSize = CGSizeMake(540, 960);
        }
            break;
        case LFLiveVideoQuality_Medium2:{
            self.sessionPreset = LFCaptureSessionPreset540x960;
            self.videoFrameRate = 24;
            self.videoMaxFrameRate = 24;
            self.videoMinFrameRate = 12;
            self.videoBitRate = 800 * 1000;
            self.videoMaxBitRate = 960 * 1000;
            self.videoMinBitRate = 500 * 1000;
            self.videoSize = CGSizeMake(540, 960);
        }
            break;
        case LFLiveVideoQuality_Medium3:{
            self.sessionPreset = LFCaptureSessionPreset540x960;
            self.videoFrameRate = 30;
            self.videoMaxFrameRate = 30;
            self.videoMinFrameRate = 15;
            self.videoBitRate = 1000 * 1000;
            self.videoMaxBitRate = 1200 * 1000;
            self.videoMinBitRate = 500 * 1000;
            self.videoSize = CGSizeMake(540, 960);
        }
            break;
        case LFLiveVideoQuality_High1:{
            self.sessionPreset = LFCaptureSessionPreset720x1280;
            self.videoFrameRate = 15;
            self.videoMaxFrameRate = 15;
            self.videoMinFrameRate = 10;
            self.videoBitRate = 1000 * 1000;
            self.videoMaxBitRate = 1200 * 1000;
            self.videoMinBitRate = 500 * 1000;
            self.videoSize = CGSizeMake(720, 1280);
        }
            break;
        case LFLiveVideoQuality_High2:{
            self.sessionPreset = LFCaptureSessionPreset720x1280;
            self.videoFrameRate = 24;
            self.videoMaxFrameRate = 24;
            self.videoMinFrameRate = 12;
            self.videoBitRate = 1200 * 1000;
            self.videoMaxBitRate = 1440 * 1000;
            self.videoMinBitRate = 800 * 1000;
            self.videoSize = CGSizeMake(720, 1280);
        }
            break;
        case LFLiveVideoQuality_High3:{
            self.sessionPreset = LFCaptureSessionPreset720x1280;
            self.videoFrameRate = 30;
            self.videoMaxFrameRate = 30;
            self.videoMinFrameRate = 15;
            self.videoBitRate = 1200 * 1000;
            self.videoMaxBitRate = 1440 * 1000;
            self.videoMinBitRate = 500 * 1000;
            self.videoSize = CGSizeMake(720, 1280);
        }
            break;
        default:
            break;
    }
    
    //VEVOLIVEHACK: does not use the autorotation feature; instead our video configuration connects two AVCaptureConnections to the AVCaptureSession in GPUImageVideoCamera: the default output connection on the session which we lock into landscapeLeft (for the front facing camera), and one for an AVCaptureVideoPreviewLayer locked in portrait for the initial video preview. LFLiveKit, tho, as designed expects to start with the front facing camera in portrait and with autorotation on -- obvious from how all the above default configurations' videoSize aspects are portrait.  So here we convert the default output connection aspect from portrait to landscape
    self.videoSize = CGSizeMake(self.videoSize.height, self.videoSize.width);
    
    self.sessionPreset = [self supportSessionPreset:self.sessionPreset];
    self.videoMaxKeyframeInterval = self.videoFrameRate*2;
    CGSize size = self.videoSize;
    if(self.landscape) {
        self.videoSize = CGSizeMake(size.height, size.width);
    } else {
        self.videoSize = CGSizeMake(size.width, size.height);
    }
}

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

- (void)setVideoMaxBitRate:(NSUInteger)videoMaxBitRate {
    if (videoMaxBitRate <= _videoBitRate) return;
    _videoMaxBitRate = videoMaxBitRate;
}

- (void)setVideoMinBitRate:(NSUInteger)videoMinBitRate {
    if (videoMinBitRate >= _videoBitRate) return;
    _videoMinBitRate = videoMinBitRate;
}

- (void)setVideoMaxFrameRate:(NSUInteger)videoMaxFrameRate {
    if (videoMaxFrameRate <= _videoFrameRate) return;
    _videoMaxFrameRate = videoMaxFrameRate;
}

- (void)setVideoMinFrameRate:(NSUInteger)videoMinFrameRate {
    if (videoMinFrameRate >= _videoFrameRate) return;
    _videoMinFrameRate = videoMinFrameRate;
}

- (void)setSessionPreset:(LFLiveVideoSessionPreset)sessionPreset{
    _sessionPreset = sessionPreset;
    _sessionPreset = [self supportSessionPreset:sessionPreset];
}

#pragma mark -- Custom Method
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

#pragma mark -- encoder
- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:[NSValue valueWithCGSize:self.videoSize] forKey:@"videoSize"];
    [aCoder encodeObject:@(self.videoFrameRate) forKey:@"videoFrameRate"];
    [aCoder encodeObject:@(self.videoMaxFrameRate) forKey:@"videoMaxFrameRate"];
    [aCoder encodeObject:@(self.videoMinFrameRate) forKey:@"videoMinFrameRate"];
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
    _videoMaxFrameRate = [[aDecoder decodeObjectForKey:@"videoMaxFrameRate"] unsignedIntegerValue];
    _videoMinFrameRate = [[aDecoder decodeObjectForKey:@"videoMinFrameRate"] unsignedIntegerValue];
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
                        @(self.videoMaxFrameRate),
                        @(self.videoMinFrameRate),
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

- (BOOL)isEqual:(id)other {
    if (other == self) {
        return YES;
    } else if (![super isEqual:other]) {
        return NO;
    } else {
        LFLiveVideoConfiguration *object = other;
        return CGSizeEqualToSize(object.videoSize, self.videoSize) &&
               object.videoFrameRate == self.videoFrameRate &&
               object.videoMaxFrameRate == self.videoMaxFrameRate &&
               object.videoMinFrameRate == self.videoMinFrameRate &&
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

- (id)copyWithZone:(nullable NSZone *)zone {
    LFLiveVideoConfiguration *other = [self.class defaultConfiguration];
    return other;
}

- (NSString *)description {
    NSMutableString *desc = @"".mutableCopy;
    [desc appendFormat:@"<LFLiveVideoConfiguration: %p>", self];
    [desc appendFormat:@" videoSize:%@", NSStringFromCGSize(self.videoSize)];
    [desc appendFormat:@" videoSizeRespectingAspectRatio:%zi",self.videoSizeRespectingAspectRatio];
    [desc appendFormat:@" videoFrameRate:%zi", self.videoFrameRate];
    [desc appendFormat:@" videoMaxFrameRate:%zi", self.videoMaxFrameRate];
    [desc appendFormat:@" videoMinFrameRate:%zi", self.videoMinFrameRate];
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
