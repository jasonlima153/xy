#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Security/Security.h>
#import <PushKit/PushKit.h>

static AVAudioPlayer *globalPulsePlayer = nil;
static dispatch_source_t backgroundPulseTimer = nil;
static dispatch_source_t reconnectPulseTimer = nil;

// ============================================================================
// 1. UTDID 动态离散哈希化（解决服务器同标识风控与互踢）
// ============================================================================
%hook UTDIDIphoneSDK
+ (NSString *)getUtdid {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    
    // 如果是官方原版，放行原生逻辑，不对原版造成任何干扰
    if ([bundleId isEqualToString:@"com.taobao.fleamarket"]) {
        return %orig;
    }
    
    // 动态生成算法：基于包名哈希确保多开分身 1、2、3 各不相同且永久固定
    NSUInteger bundleHash = [bundleId hash];
    // 混合一个固定盐值，生成看起来随机但对该分身唯一的特征串
    NSString *seed = [NSString stringWithFormat:@"XianYuMulti_%lu_EMAS", (unsigned long)bundleHash];
    NSData *seedData = [seed dataUsingEncoding:NSUTF8StringEncoding];
    NSString *base64Str = [seedData base64EncodedStringWithOptions:0];
    
    // 严格格式规整：裁剪或填充至阿里网关标准的 24 位 Base64 长度
    if (base64Str.length > 24) {
        base64Str = [base64Str substringToIndex:24];
    }
    while (base64Str.length < 24) {
        base64Str = [base64Str stringByAppendingString:@"="];
    }
    
    NSLog(@"[XianYu-Perfect] 动态多开 UTDID 成功离散化: %@", base64Str);
    return base64Str;
}
%end

// ============================================================================
// 2. 绕过重签后 Keychain 权限域隔离（解决登录凭证读取 errSecItemNotFound）
// ============================================================================
%hookf(OSStatus, SecItemAdd, CFDictionaryRef query, CFTypeRef *result) {
    NSMutableDictionary *modified = [(__bridge NSDictionary *)query mutableCopy];
    if (modified[(__bridge id)kSecAttrAccessGroup]) {
        [modified removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
    }
    return %orig((__bridge CFDictionaryRef)modified, result);
}

%hookf(OSStatus, SecItemCopyMatching, CFDictionaryRef query, CFTypeRef *result) {
    NSMutableDictionary *modified = [(__bridge NSDictionary *)query mutableCopy];
    if (modified[(__bridge id)kSecAttrAccessGroup]) {
        [modified removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
    }
    return %orig((__bridge CFDictionaryRef)modified, result);
}

// ============================================================================
// 3. 拦截下线指令（兜底防踢：强行吞掉控制命令网关的 kickout 指令）
// ============================================================================
%hook TBSDKPushControlCmd
- (void)parseControlCommand:(NSDictionary *)commandDict {
    if (commandDict) {
        NSString *cmdType = commandDict[@"cmdType"];
        if ([cmdType isEqualToString:@"kickout"] || [commandDict[@"reason"] isEqualToString:@"duplicate_login"]) {
            NSLog(@"[XianYu-Perfect] 成功捕获并吞噬阿里服务器下发的多开下线指令，维持长连接不断。");
            return; // 强行斩断下线链路
        }
    }
    %orig;
}
%end

// ============================================================================
// 4. 阻止阿里 SDK 感知后台切换（阻止主动断开 AccsVirtualSocket）
// ============================================================================
%hook FMAccsManager

// 拦截后台通知：阻止阿里 SDK 主动断开长连接
- (void)applicationDidEnterBackground {
    NSLog(@"[XianYu-Patch] 拦截业务层切后台通知，欺骗长连接保持前台活跃状态！");
    // 不调用 %orig，让阿里 SDK 认为应用从未进入后台
    // 同时启动我们自己的脉冲保活定时器
    
    if (backgroundPulseTimer == nil) {
        backgroundPulseTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
        // 每 15 秒触发一次（比 iOS 30 秒挂起临界点更早，且比 25 秒更频繁）
        dispatch_source_set_timer(backgroundPulseTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 15 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
        
        dispatch_source_set_event_handler(backgroundPulseTimer, ^{
            @autoreleasepool {
                ExecuteAudioCpuPulse();
            }
        });
        dispatch_resume(backgroundPulseTimer);
    }
}

// 拦截前台通知：正常处理，但清理定时器
- (void)applicationWillEnterForeground {
    %orig;
    if (backgroundPulseTimer) {
        dispatch_source_cancel(backgroundPulseTimer);
        backgroundPulseTimer = nil;
    }
    if (reconnectPulseTimer) {
        dispatch_source_cancel(reconnectPulseTimer);
        reconnectPulseTimer = nil;
    }
    [[AVAudioSession sharedInstance] setActive:NO error:nil];
    NSLog(@"[XianYu-Patch] 返回前台：注销所有脉冲保活状态机。");
}
%end

// ============================================================================
// 5. 拦截 AccsVirtualSocket 网络状态变更（状态守护 + 自动重连）
// ============================================================================
%hook AccsVirtualSocket

- (void)OnNetworkStatusChanged:(int)status {
    NSLog(@"[XianYu-Patch] ACCS 底层网络状态变更: %d", status);
    
    // 如果状态变为断开（通常 0 或负数代表断开），记录日志
    if (status <= 0) {
        NSLog(@"[XianYu-Patch] 检测到 ACCS 连接断开，将在下次脉冲中强制重连！");
    }
    
    %orig(status);
}

// 拦截主动断开方法：阻止阿里 SDK 在后台主动断开连接
- (void)Disconnect {
    NSLog(@"[XianYu-Patch] 拦截 AccsVirtualSocket::Disconnect，阻止主动断开！");
    // 不调用 %orig，直接返回，保持连接不断
    return;
}

// 拦截挂起方法：阻止阿里 SDK 挂起连接
- (void)suspendConnection {
    NSLog(@"[XianYu-Patch] 拦截 AccsVirtualSocket::suspendConnection，阻止连接挂起！");
    // 不调用 %orig，直接返回
    return;
}

%end

// ============================================================================
// 6. 重构脉冲保活：采用生命周期伪装法 + 强制重连
// ============================================================================
void ExecuteAudioCpuPulse() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 内存动态生成全零静音流，杜绝物理文件路径加载闪退
        char silentBuffer[512] = {0}; 
        NSData *silentData = [NSData dataWithBytes:silentBuffer length:512];
        globalPulsePlayer = [[AVAudioPlayer alloc] initWithData:silentData error:nil];
        globalPulsePlayer.volume = 0.0; 
    });
    
    // 短暂激活音频通道并播放 0.05 秒，瞬间把即将被系统 Suspended 的 CPU 时间片拉回 Active 状态
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback 
                                     withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    
    [globalPulsePlayer play];
    
    // 脉冲充能完毕后，0.05 秒后立即停止音频，让 CPU 重新进入浅休眠
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [globalPulsePlayer stop];
        
        // 【核心改动】模拟前台事件：伪造生命周期回到前台，激活 C++ Socket 内部状态机
        id manager = [NSClassFromString(@"FMAccsManager") performSelector:@selector(sharedManager)];
        if (manager) {
            NSLog(@"[XianYu-Patch] 脉冲触发：伪造前台事件，强拉 ACCS 数据流...");
            
            // 1. 伪造回到前台，激活 ACCS 内部状态机
            if ([manager respondsToSelector:@selector(applicationWillEnterForeground)]) {
                [manager performSelector:@selector(applicationWillEnterForeground)];
            }
            
            // 2. 强制重连
            if ([manager respondsToSelector:@selector(reconnectIfNeeded)]) {
                [manager performSelector:@selector(reconnectIfNeeded)];
            }
            
            // 3. 伪造再次进入后台（但不触发断开），保持 SDK 内部状态一致
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NSLog(@"[XianYu-Patch] 脉冲完成：伪造后台事件（不触发断开），维持状态机平衡。");
                // 只调用 applicationDidEnterBackground 的 %orig 部分（不触发我们的 Hook）
                // 通过直接操作 AccsVirtualSocket 保持连接
                id accsSocket = [NSClassFromString(@"AccsVirtualSocket") performSelector:@selector(sharedInstance)];
                if (accsSocket && [accsSocket respondsToSelector:@selector(Connect)]) {
                    [accsSocket performSelector:@selector(Connect)];
                }
            });
        }
    });
}

// ============================================================================
// 7. 高频重连守护定时器（每 4 秒检测一次连接状态）
// ============================================================================
void StartReconnectGuard() {
    if (reconnectPulseTimer) return;
    
    reconnectPulseTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    // 每 4 秒检测一次连接状态，确保在阿里 SDK 内部断开时立刻恢复
    dispatch_source_set_timer(reconnectPulseTimer, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), 4 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
    
    dispatch_source_set_event_handler(reconnectPulseTimer, ^{
        @autoreleasepool {
            id manager = [NSClassFromString(@"FMAccsManager") performSelector:@selector(sharedManager)];
            if (manager && [manager respondsToSelector:@selector(reconnectIfNeeded)]) {
                NSLog(@"[XianYu-Patch] 4秒守护定时器：检测 ACCS 连接健康状态...");
                [manager performSelector:@selector(reconnectIfNeeded)];
            }
            
            // 同时尝试直接操作 AccsVirtualSocket
            id accsSocket = [NSClassFromString(@"AccsVirtualSocket") performSelector:@selector(sharedInstance)];
            if (accsSocket && [accsSocket respondsToSelector:@selector(Connect)]) {
                [accsSocket performSelector:@selector(Connect)];
            }
        }
    });
    dispatch_resume(reconnectPulseTimer);
}

// ============================================================================
// 8. 丢弃由于改 Bundle ID 而失效的 PushKit (VoIP) 注册，防止无效系统报错
// ============================================================================
%hook PKPushRegistry
- (void)setDesiredPushTypes:(NSSet<PKPushType> *)pushTypes {
    // 改了包名后注册 VoIP 推送会导致 iOS 系统向控制台持续报错或抛出权限异常。
    // 我们在这里如果是多开分身，直接传入空集合，优雅地关闭已经无法使用的 VoIP 原生通道，全力保留本地 ACCS 即可。
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    if (![bundleId isEqualToString:@"com.taobao.fleamarket"]) {
        %orig([NSSet set]); 
        return;
    }
    %orig;
}
%end

// ============================================================================
// 9. 应用启动时初始化高频守护
// ============================================================================
%hook UIApplication
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    BOOL result = %orig;
    NSLog(@"[XianYu-Patch] 应用启动：初始化 4 秒高频重连守护定时器...");
    StartReconnectGuard();
    return result;
}
%end