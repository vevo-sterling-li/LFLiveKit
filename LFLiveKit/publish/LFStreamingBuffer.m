//
//  LFStreamingBuffer.m
//  LFLiveKit
//
//  Created by LaiFeng on 16/5/20.
//  Copyright © 2016年 LaiFeng All rights reserved.
//

#import "LFStreamingBuffer.h"
#import "NSMutableArray+LFAdd.h"


static const NSUInteger defaultSortBufferMaxCount = 5;///< 排序10个内 (Sort within 10)

//static const NSUInteger defaultUpdateInterval = 1;///< 更新频率为1s
//static const NSUInteger defaultCallBackInterval = 5;///< 5s计时一次

//JK: converted interval to floats for shorter interval that 1 second
///defaultCallbackInterval is frequency at which we evaluate frame queue size trend
static const NSTimeInterval defaultCallBackInterval_f = 0.5;
static const NSInteger defaultNumFrameQueueCountSnapshots = 5;
static const NSTimeInterval defaultUpdateInterval_f = defaultCallBackInterval_f / (NSTimeInterval)defaultNumFrameQueueCountSnapshots;

static const NSUInteger defaultSendBufferMaxCount = 600;///< 最大缓冲区为600

@interface LFStreamingBuffer (){
    dispatch_semaphore_t _lock;
}

@property (nonatomic, strong) NSMutableArray <LFFrame *> *sortList;
@property (nonatomic, strong, readwrite) NSMutableArray <LFFrame *> *list;
@property (nonatomic, strong) NSMutableArray *thresholdList;

/** 处理buffer缓冲区情况 (handling buffer conditions) */
//@property (nonatomic, assign) NSInteger currentInterval;
@property (nonatomic, assign) NSTimeInterval currentInterval_f;
//@property (nonatomic, assign) NSInteger callBackInterval;
@property (nonatomic, assign) NSTimeInterval callBackInterval_f;
//@property (nonatomic, assign) NSInteger updateInterval;
@property (nonatomic, assign) NSTimeInterval updateInterval_f;
@property (nonatomic, assign) BOOL startTimer;

@end

@implementation LFStreamingBuffer

- (instancetype)init {
    if (self = [super init]) {
        
        _lock = dispatch_semaphore_create(1);
//        self.updateInterval = defaultUpdateInterval;
        self.updateInterval_f = defaultUpdateInterval_f;
//        self.callBackInterval = defaultCallBackInterval;
        self.callBackInterval_f = defaultCallBackInterval_f;
        self.maxCount = defaultSendBufferMaxCount;
        self.lastDropFrames = 0;
        self.startTimer = NO;
    }
    return self;
}

- (void)dealloc {
}

#pragma mark -- Custom
///main function to call to add a frame to the streaming frame buffer
- (void)appendObject:(LFFrame *)frame {
    if (!frame) return;
    
    //initiate the regular-interval timer that evaluates buffer state to recommend video bitrate adjustments
    if (!_startTimer) {
        _startTimer = YES;
        [self tick];
    }

    dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
    
    //frame buffer private property 'sortList' is required because frame encoding could be concurrent and, since some frames may encode faster than others, video frames may be delivered out of sequence. Once the buffer is full, it is sorted and the first (oldest) frame is popped and appended to public property 'list' (which maintains the ordered list of frames to be sent)
    //TODO: since we are only inserting one frame, an insertion sort would be much faster (O(n) vs O(nlogn)
    [self.sortList addObject:frame];
    if (self.sortList.count >= defaultSortBufferMaxCount) {
        ///< 排序 (sort)
        //TODO: insertion sort on add
		[self.sortList sortUsingFunction:frameDataCompare context:nil];
        /// 丢帧 (drop the frame)
        [self removeExpireFrame];
        /// 添加至缓冲区 (add to the buffer)
        LFFrame *firstFrame = [self.sortList lfPopFirstObject];

        if (firstFrame) [self.list addObject:firstFrame];
    }
    dispatch_semaphore_signal(_lock);
}

- (LFFrame *)popFirstObject {
    dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
    LFFrame *firstFrame = [self.list lfPopFirstObject];
    dispatch_semaphore_signal(_lock);
    return firstFrame;
}

- (void)removeAllObject {
    dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
    [self.list removeAllObjects];
    dispatch_semaphore_signal(_lock);
}

- (void)removeExpireFrame {
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

NSInteger frameDataCompare(id obj1, id obj2, void *context){
    LFFrame *frame1 = (LFFrame *)obj1;
    LFFrame *frame2 = (LFFrame *)obj2;

    if (frame1.timestamp == frame2.timestamp)
        return NSOrderedSame;
    else if (frame1.timestamp > frame2.timestamp)
        return NSOrderedDescending;
    return NSOrderedAscending;
}

- (LFLiveBuffferState)currentBufferState {
    NSInteger currentCount = 0;
    NSInteger increaseCount = 0;
    NSInteger decreaseCount = 0;

    for (NSNumber *number in self.thresholdList) {
        //count currentCount == 0 and number == previous count for decrease
        if (number.integerValue > currentCount) {
            increaseCount++;
        } else{
            decreaseCount++;
        }
        currentCount = [number integerValue];
    }

    //increase/decrease tendency must be unanimous to report
    if (increaseCount >= defaultNumFrameQueueCountSnapshots) { //self.callBackInterval) {
        return LFLiveBuffferIncrease;
    }
    else if (decreaseCount >= defaultNumFrameQueueCountSnapshots) { //self.callBackInterval) {
        return LFLiveBuffferDecline;
    }
    //else unknown
    return LFLiveBuffferUnknown;
}

#pragma mark -- Setter Getter
- (NSMutableArray *)list {
    if (!_list) {
        _list = [[NSMutableArray alloc] init];
    }
    return _list;
}

- (NSMutableArray *)sortList {
    if (!_sortList) {
        _sortList = [[NSMutableArray alloc] init];
    }
    return _sortList;
}

- (NSMutableArray *)thresholdList {
    if (!_thresholdList) {
        _thresholdList = [[NSMutableArray alloc] init];
    }
    return _thresholdList;
}

#pragma mark -- 采样
//each tick calls records the current size of frame queue 'list' in thresholdList
- (void)tick {
//    fprintf(stdout,"[LFStreamingBuffer/tick]...list=%s\n",self.list.description.UTF8String);
    /** 采样 3个阶段   如果网络都是好或者都是差给回调 (Sampling 3 stages If the network is good or both are poor callbacks)*/
    _currentInterval_f += self.updateInterval_f;

    //capture current size of frame queue 'list'
    //synchronize access to list.count
    dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
    [self.thresholdList addObject:@(self.list.count)];
    dispatch_semaphore_signal(_lock);
    
    
    //evaluate frame queue 'list': are the number of frames to be sent increasing or decreasing over time?
    if (self.currentInterval_f >= self.callBackInterval_f) {
//        fprintf(stdout,"  thresholdList=%s\n",self.thresholdList.description.UTF8String);
        
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
        [self.thresholdList removeAllObjects];
    }
    
    __weak typeof(self) _self = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.updateInterval_f * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(_self) self = _self;
        [self tick];
    });
}

@end
