//
//  a.m
//  APlay
//
//  Created by lincoln on 2018/6/8.
//  Copyright © 2018年 SelfStudio. All rights reserved.
//

#import "AVAudioSession+Workaround.h"
@import AVFoundation;
@implementation AVAduioSessionWorkaround
+(NSError*) setPlaybackCategory {
    NSError *error = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error: &error];
    return error;
}
@end
