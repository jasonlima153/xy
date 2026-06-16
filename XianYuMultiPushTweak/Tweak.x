#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Security/Security.h>
#import <PushKit/PushKit.h>

static AVAudioPlayer *globalPulsePlayer = nil;
static dispatch_source_t backgroundPulseTimer = nil;

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
// 4. 25秒间歇性音频脉冲保活（解决长期常驻的电量消耗与 iOS 系统高耗电拉清单）
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
    
    // 脉冲充能完毕后，0.05 秒后立即停止音频，让 CPU 重新进入浅休眠，达到极致省电效果
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [globalPulsePlayer stop];
        // 强制触发闲鱼底层 ACCS 连接健康检查，断线则立刻触发重连
        id manager = [NSClassFromString(@"FMAccsManager") performSelector:@selector(sharedManager)];
        if ([manager respondsToSelector:@selector(reconnectIfNeeded)]) {
            [manager performSelector:@selector(reconnectIfNeeded)];
        }
    });
}

%hook FMAccsManager
- (void)applicationDidEnterBackground {
    %orig;
    NSLog(@"[XianYu-Perfect] 进入后台：启动25秒间歇性脉冲断续保活状态机...");
    
    if (backgroundPulseTimer == nil) {
        backgroundPulseTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
        // 在 iOS 30秒挂起临界点之前（设置 25 秒），精准给进程打入"强心针"
        dispatch_source_set_timer(backgroundPulseTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 25 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
        
        dispatch_source_set_event_handler(backgroundPulseTimer, ^{
            @autoreleasepool {
                ExecuteAudioCpuPulse();
            }
        });
        dispatch_resume(backgroundPulseTimer);
    }
}

- (void)applicationWillEnterForeground {
    %orig;
    if (backgroundPulseTimer) {
        dispatch_source_cancel(backgroundPulseTimer);
        backgroundPulseTimer = nil;
    }
    [[AVAudioSession sharedInstance] setActive:NO error:nil];
    NSLog(@"[XianYu-Perfect] 返回前台：注销脉冲保活状态机。");
}
%end

// ============================================================================
// 5. 丢弃由于改 Bundle ID 而失效的 PushKit (VoIP) 注册，防止无效系统报错
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