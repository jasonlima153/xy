#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Security/Security.h>

static AVAudioPlayer *ultimateAudioPlayer = nil;

// ============================================================================
// 1. 【核心绝杀】全局 Bundle ID 伪装（欺骗 SecurityGuard 和阿里网络库）
// ============================================================================
// 强行把 NSBundle 的 bundleIdentifier 钩住。
// 当 SecurityGuard 运行时试图读取包名，我们强行返回官方原包名。
// 这样安全图片校验就会 100% 通过，网络请求在后台绝不会报 0x400 签名错误！

%hook NSBundle

- (NSString *)bundleIdentifier {
    NSString *realBundleID = %orig;

    // 如果发现是多开的包名，在应用运行时全部强行伪装成原包名！
    if ([realBundleID containsString:@"fleamarket"]) {
        return @"com.taobao.fleamarket";
    }
    return realBundleID;
}

%end

// ============================================================================
// 2. UTDID 动态离散哈希化（解决多开分身 ClientID 冲突与互踢）
// ============================================================================
%hook UTDIDIphoneSDK
+ (NSString *)getUtdid {
    // 获取原生 UTDID。由于我们在上面已经把包名伪装成了真正的官方包，
    // 这里 %orig 拿到的将是原版合法的、通过了阿里校验的 UTDID。
    NSString *originalUtdid = %orig;

    // 为了防止分身和原版 App 拥有完全相同的 UTDID 导致在服务器端互相顶掉下线，
    // 我们在这里对分身返回一个尾部经过微调、但符合 24 位 Base64 格式的专属唯一 UTDID。
    if (originalUtdid && originalUtdid.length == 24) {
        NSString *prefix = [originalUtdid substringToIndex:20];
        // 确保分身 1 和原版在服务器眼里是两台不同的设备，实现多开同时在线不互踢！
        NSString *fakeUtdid = [NSString stringWithFormat:@"%@A1B=", prefix];
        NSLog(@"[XianYu-Fake] 成功为改包名分身生成不冲突的 UTDID: %@", fakeUtdid);
        return fakeUtdid;
    }
    return originalUtdid;
}
%end

// ============================================================================
// 3. 24小时全天候死循环音频保活（锁死网卡，打破4秒断流魔咒）
// ============================================================================
void StartUltimateAudioKeeper() {
    if (ultimateAudioPlayer && ultimateAudioPlayer.isPlaying) return;

    // 内存动态生成全零静音流
    char silenceBuf[1024] = {0};
    NSData *silenceData = [NSData dataWithBytes:silenceBuf length:1024];

    ultimateAudioPlayer = [[AVAudioPlayer alloc] initWithData:silenceData error:nil];
    ultimateAudioPlayer.numberOfLoops = -1; // 真正的无限循环
    ultimateAudioPlayer.volume = 0.01;      // 保持极低物理音量，混音不打断系统

    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                     withOptions:AVAudioSessionCategoryOptionMixWithOthers
                                           error:nil];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];

    [ultimateAudioPlayer play];
    NSLog(@"[XianYu-Fake] 开启全天候死循环音频，强行锁死系统网卡不被挂起。");
}

%hook FMAccsManager
- (void)applicationDidEnterBackground {
    // 绝对不调用 %orig; 彻底斩断业务层的主动断连逻辑
    NSLog(@"[XianYu-Fake] 屏蔽业务层切后台通知，强行保持 ACCS 状态机在线。");

    dispatch_async(dispatch_get_main_queue(), ^{
        StartUltimateAudioKeeper();
    });
}
%end

// ============================================================================
// 4. 移除 Keychain Group 限制（解决改包名后无法读取登录 Session 的闪退）
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

// ============================================================================
// 5. 强行吞掉服务器下发的互踢指令
// ============================================================================
%hook TBSDKPushControlCmd
- (void)parseControlCommand:(NSDictionary *)commandDict {
    if (commandDict) {
        NSString *cmdType = commandDict[@"cmdType"];
        if ([cmdType isEqualToString:@"kickout"]) {
            NSLog(@"[XianYu-Fake] 拦截到服务器下发的多开下线指令，已强行吞掉。");
            return;
        }
    }
    %orig;
}
%end
