//
//  LFStreamingBuffer.m
//  LFLiveKit
//
//  Created by LaiFeng on 16/5/20.
//  Copyright © 2016年 LaiFeng All rights reserved.
//

#import "LFStreamingBuffer.h"
#import "NSMutableArray+LFAdd.h"


//---private constants---
//static const NSUInteger defaultSortBufferMaxCount = 45;///< 排序10个内 (Sort within 10)
static const NSUInteger listBufferOptimalSize = 24;    //~ 8 frames as there are ~3 audio frames per every ~2 video frame

//static const NSUInteger defaultUpdateInterval = 1;///< 更新频率为1s
//static const NSUInteger defaultCallBackInterval = 5;///< 5s计时一次

//JK: converted interval to floats for shorter interval that 1 second
///defaultCallbackInterval is frequency at which we evaluate frame queue size trend
static const NSTimeInterval defaultCallBackInterval_f = 0.5;
static const NSInteger defaultNumFrameQueueCountSnapshots = 5;
static const NSTimeInterval defaultUpdateInterval_f = defaultCallBackInterval_f / (NSTimeInterval)defaultNumFrameQueueCountSnapshots;

static const NSUInteger defaultSendBufferMaxCount = 600;///< 最大缓冲区为600



//=====================================================================================================
/*
 LFStreamingBuffer maintains a 2 level buffer.
 
 The first level buffer ensures against frames arriving from the encoder out of sequence -- but I can't find evidence that this is required or correct.  One imagines that this could happen if the encoder is encoding multiple frames concurrently, but I find no documentation that suggests this is the case.  Worse, encoder's have a configurable option to allow frame reordering which is required to allow for B frames. But if this is the case, the decoder requires receiving frames in encoder output order, so sorting them here is incorrect.
 Fortunately, we do not want B frame encoding so the allow frame reordering option is off.
 
 The second level buffer is for enqueing frames to be sent -- but the implementation here doesn't require a threshold for buffering.
 */
 
@interface LFStreamingBuffer (){
    dispatch_semaphore_t _lock;
}

//@property (nonatomic, strong) NSMutableArray <LFFrame *> *sortList;
//@property (nonatomic, strong, readwrite) NSMutableArray <LFFrame *> *list;
@property (nonatomic, strong, readwrite) NSMutableArray <LFFrame *> *initialList;
@property (nonatomic, strong) NSMutableArray *thresholdList;
@property (nonatomic, assign) BOOL initialBufferFull;

/** 处理buffer缓冲区情况 (handling buffer conditions) */
//@property (nonatomic, assign) NSInteger currentInterval;
@property (nonatomic, assign) NSTimeInterval currentInterval_f;
//@property (nonatomic, assign) NSInteger callBackInterval;
@property (nonatomic, assign) NSTimeInterval callBackInterval_f;
//@property (nonatomic, assign) NSInteger updateInterval;
@property (nonatomic, assign) NSTimeInterval updateInterval_f;
@property (nonatomic, assign) BOOL startTimer;
@property (nonatomic,strong) dispatch_queue_t tickQ;
@property (nonatomic,strong) dispatch_source_t tickS;

@end


@implementation LFStreamingBuffer

#pragma mark - init
- (instancetype)init {
    if (self = [super init]) {
        _initialBufferFull = NO;
        
        //lock synchronizes access to 'list' and 'initialList'
        _lock = dispatch_semaphore_create(1);
        _list = [[NSMutableArray alloc] init];
        _initialList = [[NSMutableArray alloc] init];
        
        //for tracking buffer size
        _thresholdList = [[NSMutableArray alloc] init];
        
        //track 'list' size for adaptive streaming quality
//        self.updateInterval = defaultUpdateInterval;
        _updateInterval_f = defaultUpdateInterval_f;
//        self.callBackInterval = defaultCallBackInterval;
        _callBackInterval_f = defaultCallBackInterval_f;
        _startTimer = NO;
        _lastDropFrames = 0;
        
        //set limit on 'list' size which if over, then drop old frames
        _maxCount = defaultSendBufferMaxCount;
        
        _tickQ = dispatch_queue_create("com.lflivekit.streamingBufferTickQ", DISPATCH_QUEUE_SERIAL);
        _tickS = nil;
    }
    return self;
}

- (void)dealloc {
    if (_tickS) {
        dispatch_source_cancel(_tickS);
    }
}


//-----------------------------------------------------------------------------------------------------
#pragma mark - sort buffer ops
///main function to call to add a frame to the streaming frame buffer
- (void)appendObject:(LFFrame *)frame {
    if (!frame) return;

    dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
    
    //3 states to consider:
    //  1) we just started streaming and so need to build up a short buffer before we offer frames to to send
    //  2) short buffer is filled and so move those buffere frames to to-be-sent buffer queue 'list'
    //  3) list is providing frames, so new frames are appended to list
    
    if (_initialBufferFull) {
        //add frame to list
        [_list addObject:frame];
//        NSInteger idx = (NSInteger)(_list.count) - 1;
//        while (idx >= 0 && frame.timestamp < [_list objectAtIndex:(NSUInteger)idx].timestamp) { idx--; }
//        [_list insertObject:frame atIndex:(NSUInteger)(idx + 1)];
        
        /// 丢帧 (limit size of `list` queue of frames to be sent)
        [self removeExpireFrame];
        
        if (!_startTimer) {
            //initiate regular interval timer that on fire evaluates buffer state to recommend video bitrate adjustments
            _startTimer = YES;
            //[self tick];
            
            //set up a timer in GCD running on a dispatch source
            _tickS = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _tickQ);
            dispatch_source_set_timer(_tickS, dispatch_time(DISPATCH_TIME_NOW,0), (int64_t)(self.updateInterval_f * NSEC_PER_SEC), 0);
            __weak typeof(self) weakSelf = self;
            dispatch_source_set_event_handler(_tickS, ^{
                [weakSelf tick];
            });
            dispatch_resume(_tickS);
        }
    }
    else if (_initialList.count >= listBufferOptimalSize) {
        //pass frames from initialList to list
        _initialBufferFull = YES;
        _list = _initialList;
        _initialList = nil;
        
        [_list addObject:frame];
//        NSInteger idx = (NSInteger)(_list.count) - 1;
//        while (idx >= 0 && frame.timestamp < [_list objectAtIndex:(NSUInteger)idx].timestamp) { idx--; }
//        [_list insertObject:frame atIndex:(NSUInteger)(idx + 1)];
    }
    else {
        //add frame to initial list buffer
        [_initialList addObject:frame];
//        NSInteger idx = (NSInteger)(_initialList.count) - 1;
//        while (idx >= 0 && frame.timestamp < [_initialList objectAtIndex:(NSUInteger)idx].timestamp) { idx--; }
//        [_initialList insertObject:frame atIndex:(NSUInteger)(idx + 1)];
    }
    dispatch_semaphore_signal(_lock);
    
}

NSInteger frameDataCompare(id obj1, id obj2, void *context){
    LFFrame *frame1 = (LFFrame *)obj1;
    LFFrame *frame2 = (LFFrame *)obj2;
    
    if (frame1.timestamp == frame2.timestamp)
        return NSOrderedSame;
    else if (frame1.timestamp > frame2.timestamp)
        return NSOrderedDescending;
    return NSOrderedAscending;
}


//-----------------------------------------------------------------------------------------------------
#pragma mark - list buffer pop
- (LFFrame *)popFirstObject {
    dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
    LFFrame *firstFrame = [self.list lfPopFirstObject];
    dispatch_semaphore_signal(_lock);
    return firstFrame;
}


//-----------------------------------------------------------------------------------------------------
#pragma mark - expire
- (void)removeExpireFrame {
    //assert: caller has _lock
    if (self.list.count < self.maxCount) return;

    NSArray *pFrames = [self expirePFrames];///< 第一个P到第一个I之间的p帧 (The first P to the first I p frames)
    if (pFrames && pFrames.count > 0) {
        self.lastDropFrames += [pFrames count];
        [self.list removeObjectsInArray:pFrames];
        //HMM: if we return here, then we could be leaving a preceding I frame in list (if on entry list was I P [P...] I ..., then list is now I I ...
        return;
    }
    //HMM: we will only be here if there are NO P frames in list -- but when would that happen??
    
    NSArray *iFrames = [self expireIFrames];///<  删除一个I帧（但一个I帧可能对应多个nal）(Delete an I frame (but an I frame may correspond to more than one nal))
    if (iFrames && iFrames.count > 0) {
        self.lastDropFrames += [iFrames count];
        [self.list removeObjectsInArray:iFrames];
        return;
    }
    
    [self.list removeAllObjects];
}

///scrape P all frames before an I frame
- (NSArray *)expirePFrames {
    //assert: caller has _lock
    NSMutableArray *pframes = [[NSMutableArray alloc] init];
    for (NSInteger index = 0; index < self.list.count; index++) {
        LFFrame *frame = [self.list objectAtIndex:index];
        if ([frame isKindOfClass:[LFVideoFrame class]]) {
            LFVideoFrame *videoFrame = (LFVideoFrame *)frame;
            //since we're not doing bidirectional predictive encoding, all P frames reference a previous I frame
            //so first frame in list may or may not be I, ie, 2 cases:
            //     I P [P...] I ...
            //     P [P...] I ...
            if (videoFrame.isKeyFrame && pframes.count > 0) {
                break;
            } else if (!videoFrame.isKeyFrame) {
                [pframes addObject:frame];
            }
        }
    }
    return pframes;
}

///scrapes one I frame from the front of list
//ASSERT: if called from removeExpireFrames, then on entry list is >600 I frames
- (NSArray *)expireIFrames {
    //assert: caller has _lock
    NSMutableArray *iframes = [[NSMutableArray alloc] init];
    uint64_t timeStamp = 0;
    for (NSInteger index = 0; index < self.list.count; index++) {
        LFFrame *frame = [self.list objectAtIndex:index];
        if ([frame isKindOfClass:[LFVideoFrame class]] && ((LFVideoFrame *)frame).isKeyFrame) {
            //HMM: unless all timestamps are 0 or unless all timestamps are the same, then this will find one I frame and then break
            if (timeStamp != 0 && timeStamp != frame.timestamp)
                break;
            [iframes addObject:frame];
            timeStamp = frame.timestamp;
        }
    }
    return iframes;
}


//-----------------------------------------------------------------------------------------------------
#pragma mark - list buffer clean up
- (void)removeAllObject {
    dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
    [_list removeAllObjects];
    dispatch_semaphore_signal(_lock);
}


//-----------------------------------------------------------------------------------------------------
#pragma mark -- Setter Getter
//- (NSMutableArray *)list {
//    if (!_list) {
//        _list = [[NSMutableArray alloc] init];
//    }
//    return _list;
//}

//- (NSMutableArray *)sortList {
//    if (!_sortList) {
//        _sortList = [[NSMutableArray alloc] init];
//    }
//    return _sortList;
//}

//- (NSMutableArray *)thresholdList {
//    if (!_thresholdList) {
//        _thresholdList = [[NSMutableArray alloc] init];
//    }
//    return _thresholdList;
//}


//-----------------------------------------------------------------------------------------------------
#pragma mark - assess buffer performance
#pragma mark -- 采样
//each tick calls records the current size of frame queue 'list' in thresholdList
- (void)tick {
//    fprintf(stdout,"[LFStreamingBuffer/tick]...list.count=%d\n",(int)self.list.count);
    /** 采样 3个阶段   如果网络都是好或者都是差给回调 (Sampling 3 stages If the network is good or both are poor callbacks)*/
    _currentInterval_f += self.updateInterval_f;

    //capture current size of frame queue 'list'
    dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);      //synchronize access to list.count
    [_thresholdList addObject:@(self.list.count)];
    dispatch_semaphore_signal(_lock);
    
    //evaluate to-be-sent-frame queue 'list': are the number of frames to be sent increasing or decreasing over time?
    if (_currentInterval_f >= _callBackInterval_f) {
        //assess buffer
        LFLiveBuffferState state = [self currentBufferState];
        
        //note: 'buffer' state 'increase' vs 'decrease' reflects frame queue size trend, NOT recommendation
        if (state == LFLiveBuffferIncrease) {
            if (self.delegate && [self.delegate respondsToSelector:@selector(streamingBuffer:bufferState:)]) {
                [self.delegate streamingBuffer:self bufferState:LFLiveBuffferIncrease];
            }
        } else if (state == LFLiveBuffferDecline) {
            if (self.delegate && [self.delegate respondsToSelector:@selector(streamingBuffer:bufferState:)]) {
                [self.delegate streamingBuffer:self bufferState:LFLiveBuffferDecline];
            }
        }

        //reset interval and thresholdList
        self.currentInterval_f = 0;
        [_thresholdList removeAllObjects];
    }
    
    //JK: now using timer
//    __weak typeof(self) _self = self;
//    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.updateInterval_f * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
//        __strong typeof(_self) self = _self;
//        [self tick];
//    });
}

- (LFLiveBuffferState)currentBufferState {
    if (_thresholdList.count < defaultNumFrameQueueCountSnapshots) {
        return LFLiveBuffferUnknown;
    }
    
    NSInteger currentCount = [[_thresholdList objectAtIndex:0] integerValue];
    NSInteger increaseCount = 0;
    NSInteger decreaseCount = 0;
    
    for (int idx=1; idx< _thresholdList.count; idx++) {
        NSInteger number = [[_thresholdList objectAtIndex:idx] integerValue];
        if (number > currentCount) {
            //buffer size increased between ticks
            increaseCount++;
        } else {
            //buffer size decreased or was the same between ticks
            decreaseCount++;
        }
        currentCount = number;
    }
    
    //increase/decrease tendency must be unanimous
    if (increaseCount >= defaultNumFrameQueueCountSnapshots - 1) { //self.callBackInterval) {
        return LFLiveBuffferIncrease;
    }
    else if (decreaseCount >= defaultNumFrameQueueCountSnapshots - 1) { //self.callBackInterval) {
        return LFLiveBuffferDecline;
    }
    //else unknown
    return LFLiveBuffferUnknown;
}


@end
