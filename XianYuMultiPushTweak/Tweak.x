#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Security/Security.h>
#import <libkern/OSAtomic.h>
#import <execinfo.h>

static AVAudioPlayer *ultimateAudioPlayer = nil;

// ============================================================================
// 1. 【硬核修复】定向堆栈伪装（只欺骗阿里加固，放行系统通知中心）
// ============================================================================
%hook NSBundle

- (NSString *)bundleIdentifier {
    NSString *realBundleID = %orig; // 拿到重签后的真实包名 (例如 com.taobao.fleamarket.multi1)

    // 只对多开分身执行伪装逻辑，原版直接放行
    if (realBundleID && ![realBundleID isEqualToString:@"com.taobao.fleamarket"]) {

        // 抓取当前调用栈的简易符号描述
        NSArray *syms = [NSThread callStackSymbols];
        if (syms && syms.count > 1) {
            NSString *callerSymbol = syms[1]; // 获取直接调用本方法的上一层堆栈

            // 核心逻辑：如果上一层调用来自于系统通知、UIKit推送分发，绝对不能伪装！
            if ([callerSymbol containsString:@"UserNotifications"] ||
                [callerSymbol containsString:@"NotificationCenter"] ||
                [callerSymbol containsString:@"libsystem_"] ||
                [callerSymbol containsString:@"CoreFoundation"]) {

                // 放行真实包名，保证本地通知（Alert/Banner）100% 能弹出来
                return realBundleID;
            }
        }

        // 阿里安全加固、ACCS 长连接重连鉴权在调用时，强行切回官方包名通过验签，打破4秒断流
        return @"com.taobao.fleamarket";
    }

    return realBundleID;
}

%end

// ============================================================================
// 2. UTDID 动态离散哈希化（保持不冲突在线）
// ============================================================================
%hook UTDIDIphoneSDK
+ (NSString *)getUtdid {
    NSString *originalUtdid = %orig;
    if (originalUtdid && originalUtdid.length == 24) {
        NSString *prefix = [originalUtdid substringToIndex:20];
        // 替换尾部 4 位，通过网关校验且防止互踢
        return [NSString stringWithFormat:@"%@M2B=", prefix];
    }
    return originalUtdid;
}
%end

// ============================================================================
// 3. 24小时常驻全天候音频保活（保持网络 Socket 长期咬合网卡）
// ============================================================================
void StartUltimateAudioKeeper() {
    if (ultimateAudioPlayer && ultimateAudioPlayer.isPlaying) return;

    char silenceBuf[1024] = {0};
    NSData *silenceData = [NSData dataWithBytes:silenceBuf length:1024];

    ultimateAudioPlayer = [[AVAudioPlayer alloc] initWithData:silenceData error:nil];
    ultimateAudioPlayer.numberOfLoops = -1;
    ultimateAudioPlayer.volume = 0.01;

    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                     withOptions:AVAudioSessionCategoryOptionMixWithOthers
                                           error:nil];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    [ultimateAudioPlayer play];
}

%hook FMAccsManager
- (void)applicationDidEnterBackground {
    // 屏蔽业务层后台主动断开事件
    dispatch_async(dispatch_get_main_queue(), ^{
        StartUltimateAudioKeeper();
    });
}
%end

// ============================================================================
// 4. Keychain 降维沙盒隔离与兜底吞掉下线指令
// ============================================================================
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
    if (commandDict && [commandDict[@"cmdType"] isEqualToString:@"kickout"]) {
        return;
    }
    %orig;
}
%end
