//
//  LFLiveVideoConfiguration.h
//  LFLiveKit
//
//  Created by LaiFeng on 16/5/20.
//  Copyright © 2016年 LaiFeng All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/// 视频分辨率(都是16：9 当此设备不支持当前分辨率，自动降低一级)
typedef NS_ENUM (NSUInteger, LFLiveVideoSessionPreset){
    /// 低分辨率
    LFCaptureSessionPreset360x640 = 0,
    /// 中分辨率
    LFCaptureSessionPreset540x960 = 1,
    /// 高分辨率
    LFCaptureSessionPreset720x1280 = 2
};

/// 视频质量
typedef NS_ENUM (NSUInteger, LFLiveVideoQuality){
    /// 分辨率： 360 *640 帧数：15 码率：500Kps
    LFLiveVideoQuality_Low1 = 0,
    /// 分辨率： 360 *640 帧数：24 码率：800Kps
    LFLiveVideoQuality_Low2 = 1,
    /// 分辨率： 360 *640 帧数：30 码率：800Kps
    LFLiveVideoQuality_Low3 = 2,
    /// 分辨率： 540 *960 帧数：15 码率：800Kps
    LFLiveVideoQuality_Medium1 = 3,
    /// 分辨率： 540 *960 帧数：24 码率：800Kps
    LFLiveVideoQuality_Medium2 = 4,
    /// 分辨率： 540 *960 帧数：30 码率：800Kps
    LFLiveVideoQuality_Medium3 = 5,
    /// 分辨率： 720 *1280 帧数：15 码率：1000Kps
    LFLiveVideoQuality_High1 = 6,
    /// 分辨率： 720 *1280 帧数：24 码率：1200Kps
    LFLiveVideoQuality_High2 = 7,
    /// 分辨率： 720 *1280 帧数：30 码率：1200Kps
    LFLiveVideoQuality_High3 = 8,
    /// 默认配置
    LFLiveVideoQuality_Default = LFLiveVideoQuality_Low2
};

@interface LFLiveVideoConfiguration : NSObject<NSCoding, NSCopying>

/// 默认视频配置
+ (nullable instancetype)defaultConfiguration;
/// 视频配置(质量)
+ (nullable instancetype)defaultConfigurationForQuality:(LFLiveVideoQuality)videoQuality;

/// 视频配置(质量 & 是否是横屏)
+ (nullable instancetype)defaultConfigurationForQuality:(LFLiveVideoQuality)videoQuality outputImageOrientation:(UIInterfaceOrientation)outputImageOrientation;

- (void)updateConfigurationBasedOnVideoQuality:(LFLiveVideoQuality)videoQuality;

#pragma mark - Attribute
///=============================================================================
/// @name Attribute
///=============================================================================
/// 视频的分辨率，宽高务必设定为 2 的倍数，否则解码播放时可能出现绿边(这个videoSizeRespectingAspectRatio设置为YES则可能会改变)
//right after initialization, videoSize is the capture output size
@property (nonatomic, assign) CGSize videoSize;

/// 输出图像是否等比例,默认为NO (The output image is the same proportion, the default is NO)
@property (nonatomic, assign) BOOL videoSizeRespectingAspectRatio;

/// 视频输出方向
@property (nonatomic, assign) UIInterfaceOrientation outputImageOrientation;

/// 自动旋转(这里只支持 left 变 right  portrait 变 portraitUpsideDown)
@property (nonatomic, assign) BOOL autorotate;

/// 视频的帧率，即 fps
//JK: we don't support changing frame rate, so made this property readonly
@property (nonatomic, readonly) NSUInteger videoFrameRate;

/// 视频的最大帧率，即 fps
//@property (nonatomic, assign) NSUInteger videoMaxFrameRate;

/// 视频的最小帧率，即 fps
//@property (nonatomic, assign) NSUInteger videoMinFrameRate;

/// 最大关键帧间隔，可设定为 fps 的2倍，影响一个 gop 的大小
//key frame max frame interval, set to 0 to let VTCompressionSession decide
@property (nonatomic, readonly) NSUInteger videoMaxKeyframeInterval;
//key frame max interval duration, set to 0 to let VTCompressionSession decide
@property (nonatomic, readonly) NSUInteger videoMaxKeyframeIntervalDuration;

/// 视频的码率，单位是 bps
@property (nonatomic, assign) NSUInteger videoBitRate;

/// 视频的最大码率，单位是 bps
@property (nonatomic, readonly) NSUInteger videoMaxBitRate;

/// 视频的最小码率，单位是 bps
@property (nonatomic, readonly) NSUInteger videoMinBitRate;

///< 分辨率
//JK: made readonly because sessionPreset must be correlated with videoQuality, video size, bitrates, etc.
@property (nonatomic, assign, readonly) LFLiveVideoSessionPreset sessionPreset;

///< ≈sde3分辨率
@property (nonatomic, assign, readonly, nonnull) NSString *avSessionPreset;

///< 是否是横屏
@property (nonatomic, assign, readonly) BOOL landscape;

///not all settings available on all devices, so sets to highest/closest quality/resolution supported by front facing camera. Changing videoQuality also changes sessionPreset, videoFrameRate, bitrate and min/max bitrate, videoSize, videoMaxKeyFrameInterval
@property (nonatomic, assign) LFLiveVideoQuality videoQuality;

- (void)refreshVideoSize;

@end
