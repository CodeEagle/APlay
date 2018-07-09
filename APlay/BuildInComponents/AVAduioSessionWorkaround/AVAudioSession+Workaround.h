//
//  AVAudioSession+Workaround.h
//  APlay
//
//  Created by lincoln on 2018/6/8.
//  Copyright © 2018年 SelfStudio. All rights reserved.
//

#import <Foundation/Foundation.h>
@interface AVAduioSessionWorkaround: NSObject
+ (NSError* __nullable) setPlaybackCategory;
@end
