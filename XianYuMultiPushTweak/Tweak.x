#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Security/Security.h>
#import <dlfcn.h>

// 全域达尔文跨进程通知的唯一标识（必须保持一致）
#define kXianYuPushShareNotification "com.taobao.fleamarket.pushshare.pulse"

static AVAudioPlayer *sharedHelperPlayer = nil;

// ============================================================================
// 1. 【核心伪装】高性能 C 级调用源过滤（解决自签改包名后 SecurityGuard 签名失败）
// ============================================================================
%hook NSBundle
- (NSString *)bundleIdentifier {
    NSString *realBundleID = %orig;

    // 如果是官方原版包名，直接放行
    if ([realBundleID isEqualToString:@"com.taobao.fleamarket"]) {
        return realBundleID;
    }

    // 自签多开环境下，利用 dladdr 提取调用源，只欺骗阿里加固，不欺骗系统通知中心
    void *returnAddress = __builtin_return_address(0);
    if (returnAddress != NULL) {
        Dl_info info;
        if (dladdr(returnAddress, &info) != 0 && info.dli_fname != NULL) {
            NSString *callerImage = [NSString stringWithUTF8String:info.dli_fname];

            if ([callerImage containsString:@"SecurityGuard"] ||
                [callerImage containsString:@"SGMain"] ||
                [callerImage containsString:@"Tnet"] ||
                [callerImage containsString:@"Runner.app/Runner"]) {

                if (![callerImage containsString:@"/System/Library/"] && ![callerImage containsString:@"/usr/lib/"]) {
                    return @"com.taobao.fleamarket";
                }
            }
        }
    }
    return realBundleID;
}
%end

// ============================================================================
// 2. 【发送端逻辑】注入"官方正版"的角色：收到消息，全域广播
// ============================================================================
%hook TBAccsReceiveAndCallBackCenter
- (void)didRecvAccsBuf:(id)buf {
    %orig; // 让正版主号正常处理并弹出原生通知

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSString *currentBundle = [[NSBundle mainBundle] bundleIdentifier];
        // 只有当前运行的是官方正版包时，才发射跨进程广播
        if ([currentBundle isEqualToString:@"com.taobao.fleamarket"]) {
            NSLog(@"[XianYu-Share] 正版基站端：长连接检测到新消息，正在向分身发射达尔文广播...");
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFSTR(kXianYuPushShareNotification),
                NULL,
                NULL,
                YES
            );
        }
    });
}
%end

// ============================================================================
// 3. 【接收端逻辑】注入"多开分身"的角色：接收广播，后台瞬间建连收信
// ============================================================================
static void OnPushSignalReceived(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    NSLog(@"[XianYu-Share] 分身哨兵端：成功捕获到基站引信！分身在后台被瞬间强行激活！");

    @autoreleasepool {
        // 1. 瞬间利用无声音频抢占 CPU 执行权，锁死网卡不被 iOS 内核挂起
        if (!sharedHelperPlayer) {
            char silenceBuf[256] = {0};
            NSData *silentData = [NSData dataWithBytes:silenceBuf length:256];
            sharedHelperPlayer = [[AVAudioPlayer alloc] initWithData:silentData error:nil];
            sharedHelperPlayer.volume = 0.0;
        }

        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                         withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
        [[AVAudioSession sharedInstance] setActive:YES error:nil];
        [sharedHelperPlayer play];

        // 2. 在网卡被激活的黄金时间内，强制唤醒分身已死或断流的 C++ ACCS 通道
        id manager = [NSClassFromString(@"FMAccsManager") performSelector:@selector(sharedManager)];
        if (manager && [manager respondsToSelector:@selector(reconnectIfNeeded)]) {
            NSLog(@"[XianYu-Share] 分身哨兵端：正在越级触发 reconnectIfNeeded 重载 TCP 管道收信...");
            [manager performSelector:@selector(reconnectIfNeeded)];
        }

        // 3. 5 秒钟足够长连接把多开账号的所有新留言拉取完毕并弹窗，随后火速关闭音频，深睡眠待机
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (sharedHelperPlayer) {
                [sharedHelperPlayer stop];
            }
            [[AVAudioSession sharedInstance] setActive:NO error:nil];
            NSLog(@"[XianYu-Share] 分身哨兵端：收信结束，分身重新潜伏休眠。");
        });
    }
}

// ============================================================================
// 4. 环境隔离与防互踢优化（Keychain 降维沙盒与 UTDID 动态离散）
// ============================================================================
%hook UTDIDIphoneSDK
+ (NSString *)getUtdid {
    NSString *originalUtdid = %orig;
    // 只有多开分身才修改 UTDID 尾部字符，确保官方原版和分身在服务器端 ClientID 不冲突
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    if (![bundleId isEqualToString:@"com.taobao.fleamarket"]) {
        if (originalUtdid && originalUtdid.length == 24) {
            NSString *prefix = [originalUtdid substringToIndex:20];
            return [NSString stringWithFormat:@"%@M2B=", prefix];
        }
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

// ============================================================================
// 5. 初始化注册：如果是多开 App，向 iOS 内核订阅全域广播
// ============================================================================
%hook UIApplication
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    BOOL result = %orig;

    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    if (![bundleId isEqualToString:@"com.taobao.fleamarket"]) {
        NSLog(@"[XianYu-Share] 检测到多开分身环境，正在向 iOS 内核注册达尔文通知监听...");
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            OnPushSignalReceived,
            CFSTR(kXianYuPushShareNotification),
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );
    }

    return result;
}
%end
