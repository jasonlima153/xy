#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Security/Security.h>
#import <dlfcn.h>

static AVAudioPlayer *ultimateAudioPlayer = nil;
static dispatch_source_t highFrequencyTimer = nil;

// ============================================================================
// 1. 高性能 C 级调用源过滤（保持包名伪装，放行系统通知中心）
// ============================================================================
%hook NSBundle
- (NSString *)bundleIdentifier {
    NSString *realBundleID = %orig;
    if ([realBundleID isEqualToString:@"com.taobao.fleamarket"]) {
        return realBundleID;
    }

    void *returnAddress = __builtin_return_address(0);
    if (returnAddress == NULL) return realBundleID;

    Dl_info info;
    if (dladdr(returnAddress, &info) != 0 && info.dli_fname != NULL) {
        NSString *callerImage = [NSString stringWithUTF8String:info.dli_fname];

        if ([callerImage containsString:@"SecurityGuard"] ||
            [callerImage containsString:@"SGMain"] ||
            [callerImage containsString:@"Tnet"] ||
            [callerImage containsString:@"Runner.app/Runner"]) {

            if (![callerImage containsString:@"/System/Library/"] &&
                ![callerImage containsString:@"/usr/lib/"]) {
                return @"com.taobao.fleamarket";
            }
        }
    }
    return realBundleID;
}
%end

// ============================================================================
// 2. 【核心绝杀】重写 FMAccsManager 生命周期，阻止底层 Tnet 进入后台挂起状态
// ============================================================================
%hook FMAccsManager

- (void)applicationDidEnterBackground {
    // 1. 绝对不调用 %orig
    // 斩断闲鱼官方业务层主动向 C++ Tnet 网络库下发的"进入后台"指令
    NSLog(@"[XianYu-Perfect] 成功斩断官方业务层后台断连信号！");

    // 2. 立即激活常驻无声音频守卫
    dispatch_async(dispatch_get_main_queue(), ^{
        if (ultimateAudioPlayer && ultimateAudioPlayer.isPlaying) return;

        char silenceBuf[512] = {0};
        NSData *silentData = [NSData dataWithBytes:silenceBuf length:512];
        ultimateAudioPlayer = [[AVAudioPlayer alloc] initWithData:silentData error:nil];
        ultimateAudioPlayer.numberOfLoops = -1;
        ultimateAudioPlayer.volume = 0.01;

        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                         withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
        [[AVAudioSession sharedInstance] setActive:YES error:nil];
        [ultimateAudioPlayer play];

        // 3. 建立 3 秒高频强拉状态机（硬撼 4 秒断流魔咒）
        if (highFrequencyTimer == nil) {
            highFrequencyTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
            dispatch_source_set_timer(highFrequencyTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 3 * NSEC_PER_SEC, 0 * NSEC_PER_SEC);

            dispatch_source_set_event_handler(highFrequencyTimer, ^{
                @autoreleasepool {
                    id manager = [NSClassFromString(@"FMAccsManager") performSelector:@selector(sharedManager)];
                    if (manager && [manager respondsToSelector:@selector(reconnectIfNeeded)]) {
                        NSLog(@"[XianYu-Perfect] 后台 3 秒高频脉冲：强行重载 ACCS 底层 TCP 通道！");
                        [manager performSelector:@selector(reconnectIfNeeded)];
                    }
                }
            });
            dispatch_resume(highFrequencyTimer);
        }
    });
}

- (void)applicationWillEnterForeground {
    %orig;
    if (highFrequencyTimer) {
        dispatch_source_cancel(highFrequencyTimer);
        highFrequencyTimer = nil;
    }
    if (ultimateAudioPlayer) {
        [ultimateAudioPlayer stop];
    }
    [[AVAudioSession sharedInstance] setActive:NO error:nil];
}
%end

// ============================================================================
// 3. UTDID 动态离散、Keychain 降维沙盒与防踢
// ============================================================================
%hook UTDIDIphoneSDK
+ (NSString *)getUtdid {
    NSString *originalUtdid = %orig;
    if (originalUtdid && originalUtdid.length == 24) {
        NSString *prefix = [originalUtdid substringToIndex:20];
        return [NSString stringWithFormat:@"%@M2B=", prefix];
    }
    return originalUtdid;
}
%end

%hookf(OSStatus, SecItemAdd, CFDictionaryRef query, CFTypeRef *result) {
    NSMutableDictionary *modified = [(__bridge NSDictionary *)query mutableCopy];
    [modified removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
    return %orig((__bridge CFDictionaryRef)modified, result);
}

%hookf(OSStatus, SecItemCopyMatching, CFDictionaryRef query, CFTypeRef *result) {
    NSMutableDictionary *modified = [(__bridge NSDictionary *)query mutableCopy];
    [modified removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
    return %orig((__bridge CFDictionaryRef)modified, result);
}

%hook TBSDKPushControlCmd
- (void)parseControlCommand:(NSDictionary *)commandDict {
    if (commandDict && [commandDict[@"cmdType"] isEqualToString:@"kickout"]) return;
    %orig;
}
%end
