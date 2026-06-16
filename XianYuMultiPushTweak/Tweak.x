#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Security/Security.h>
#import <dlfcn.h>

static AVAudioPlayer *ultimateAudioPlayer = nil;

// ============================================================================
// 1. 【完美修复】高性能 C 级调用源过滤（彻底根治 EXC_BAD_ACCESS 闪退）
// ============================================================================
%hook NSBundle

- (NSString *)bundleIdentifier {
    NSString *realBundleID = %orig; // 拿到重签后的真实包名 (例如 com.taobao.fleamarket1)

    // 如果是原版，直接放行
    if ([realBundleID isEqualToString:@"com.taobao.fleamarket"]) {
        return realBundleID;
    }

    // 极致性能：获取是谁在调用 [NSBundle bundleIdentifier] 的上层 C 函数返回地址
    void *returnAddress = __builtin_return_address(0);
    if (returnAddress == NULL) {
        return realBundleID;
    }

    // 使用 dladdr 反查该内存地址究竟属于哪个动态库（Image）
    Dl_info info;
    if (dladdr(returnAddress, &info) != 0 && info.dli_fname != NULL) {
        NSString *callerImage = [NSString stringWithUTF8String:info.dli_fname];

        // 核心判定：只有当调用者来自于阿里的安全加固组件或者网络组件时，我们才返回官方原包名欺骗它！
        if ([callerImage containsString:@"SecurityGuard"] ||
            [callerImage containsString:@"SGMain"] ||
            [callerImage containsString:@"Tnet"] ||
            [callerImage containsString:@"Runner.app/Runner"]) { // 阿里 C++ 库静态链接在 Runner 主程序内

            // 排除苹果系统层和通知中心的调用，防止 Identity Mismatch 导致的通知消失
            if (![callerImage containsString:@"/System/Library/"] &&
                ![callerImage containsString:@"/usr/lib/"]) {

                // 成功欺骗阿里加固与长连接，打破4秒断流
                return @"com.taobao.fleamarket";
            }
        }
    }

    // 其余所有情况（系统弹窗、通知中心、UIKit）一律老老实实交出真实包名，确保通知正常弹出
    return realBundleID;
}

%end

// ============================================================================
// 2. UTDID 离散化与全天候音频常驻（与前方案保持一致）
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

void StartUltimateAudioKeeper() {
    if (ultimateAudioPlayer && ultimateAudioPlayer.isPlaying) return;
    char silenceBuf[512] = {0};
    NSData *silentData = [NSData dataWithBytes:silenceBuf length:512];
    ultimateAudioPlayer = [[AVAudioPlayer alloc] initWithData:silentData error:nil];
    ultimateAudioPlayer.numberOfLoops = -1;
    ultimateAudioPlayer.volume = 0.01;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    [ultimateAudioPlayer play];
}

%hook FMAccsManager
- (void)applicationDidEnterBackground {
    dispatch_async(dispatch_get_main_queue(), ^{
        StartUltimateAudioKeeper();
    });
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
