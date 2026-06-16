#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Security/Security.h>

static AVAudioPlayer *permanentAudioPlayer = nil;

// ============================================================================
// 1. 极致保活：全天候 100% 死循环音频（不给 iOS 系统任何冻结网卡的机会）
// ============================================================================
void StartPermanentAudioKeeper() {
    if (permanentAudioPlayer && permanentAudioPlayer.isPlaying) return;

    // 内存中生成全零无损静音流
    char silenceBuf[1024] = {0};
    NSData *silenceData = [NSData dataWithBytes:silenceBuf length:1024];

    NSError *error = nil;
    permanentAudioPlayer = [[AVAudioPlayer alloc] initWithData:silenceData error:&error];
    permanentAudioPlayer.numberOfLoops = -1; // 真正的无限循环！
    permanentAudioPlayer.volume = 0.01;      // 保持极低物理音量，防止打断系统声音

    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                     withOptions:AVAudioSessionCategoryOptionMixWithOthers
                                           error:nil];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];

    [permanentAudioPlayer play];
    NSLog(@"[XianYu-Final] 开启终极常驻音频，强行锁死系统网卡不被挂起。");
}

// ============================================================================
// 2. 核心对抗：彻底屏蔽阿里网络库对"切后台"的感知（重构 FMAccsManager）
// ============================================================================
%hook FMAccsManager

- (void)applicationDidEnterBackground {
    // 绝对不调用 %orig; 彻底斩断业务层的主动断连逻辑
    NSLog(@"[XianYu-Final] 屏蔽业务层后台通知。");

    // 立即拉起全天候音频守卫
    dispatch_async(dispatch_get_main_queue(), ^{
        StartPermanentAudioKeeper();
    });
}

%end

// ============================================================================
// 3. 底层强插：当 C++ 虚拟 Socket 只要敢断开，立刻强行发起全新握手
// ============================================================================
%hook AccsVirtualSocket

- (void)OnNetworkStatusChanged:(int)status {
    // 记录所有的底层状态变化
    NSLog(@"[XianYu-Final] ACCS C++ 底层 Socket 状态发生变化: %d", status);

    %orig(status);

    // 如果状态指示连接已断开/被关闭 (假设非 1 为断开)
    if (status != 1) {
        NSLog(@"[XianYu-Final] 检测到 C++ Socket 被断开，正在越级拉活底层连接...");

        // 延迟 1 秒，避开内核网络切换引起的崩溃冲突
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // 越过所有 OC 业务检测，直接调用底层初始化和 Bind 流程
            id accsMgr = [NSClassFromString(@"TBAccsManager") performSelector:@selector(sharedInstance)];
            if (!accsMgr) {
                accsMgr = [NSClassFromString(@"TBAccsManager") alloc];
                accsMgr = [accsMgr performSelector:@selector(init)];
            }

            if (accsMgr) {
                // 强制重新执行应用与服务器握手
                NSLog(@"[XianYu-Final] 强行触发底层 Accs Bind Operation");
                id fmAccs = [NSClassFromString(@"FMAccsManager") performSelector:@selector(sharedManager)];
                if ([fmAccs respondsToSelector:@selector(reconnectIfNeeded)]) {
                    [fmAccs performSelector:@selector(reconnectIfNeeded)];
                }
            }
        });
    }
}

%end

// ============================================================================
// 4. 辅助隔离：Keychain 与 UTDID 保持离散化（防止前台互相影响）
// ============================================================================
%hook UTDIDIphoneSDK
+ (NSString *)getUtdid {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleId isEqualToString:@"com.taobao.fleamarket"]) return %orig;

    NSUInteger bundleHash = [bundleId hash];
    NSString *seed = [NSString stringWithFormat:@"XianYuMulti_%lu_EMAS", (unsigned long)bundleHash];
    NSData *seedData = [seed dataUsingEncoding:NSUTF8StringEncoding];
    NSString *base64Str = [seedData base64EncodedStringWithOptions:0];
    if (base64Str.length > 24) base64Str = [base64Str substringToIndex:24];
    while (base64Str.length < 24) base64Str = [base64Str stringByAppendingString:@"="];
    return base64Str;
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
