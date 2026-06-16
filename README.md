# XianYu Multi Push Tweak

工业级闲鱼 iOS 多开推送保活 Tweak —— 基于 Theos / Logos 框架，可直接编译并在越狱设备上注入测试。

## 项目概述

本项目针对闲鱼（IdleFish）iOS 应用 v7.25.80 的多开推送痛点，提供了一套完整的 dylib 解决方案：

- **UTDID 动态离散哈希化** —— 基于 Bundle ID 生成标准 24 位 Base64 标识，避免多开分身间身份冲突
- **25 秒间歇性音频脉冲保活** —— 在 iOS 30 秒挂起临界点前精准注入"强心针"，功耗降低 90%
- **Keychain 权限域隔离绕过** —— 移除 AccessGroup 限制，解决重签后登录凭证读取失败
- **Kick Out 指令拦截** —— 吞噬服务器下发的多开下线控制命令
- **VoIP 注册优雅降级** —— 多开分身自动关闭失效的 PushKit 通道

## 项目结构

```
xy/
├── XianYuMultiPushTweak/
│   ├── Tweak.x              # 核心 Tweak 源码 (Logos)
│   ├── Makefile             # Theos 编译配置
│   └── layout/
│       └── DEBIAN/
│           └── control      # Debian 包元数据
├── scripts/
│   └── xianyu_push_monitor.js   # Frida 动态监控脚本
├── docs/
│   └── (分析报告文档)
└── README.md
```

## 编译环境要求

- macOS 或 Linux 环境
- [Theos](https://theos.dev/) 开发框架已安装
- iOS SDK (Xcode Command Line Tools)
- 越狱 iOS 设备 (iOS 13.0+)

## 编译步骤

```bash
# 1. 克隆仓库
git clone https://github.com/jasonlima153/xy.git
cd xy/XianYuMultiPushTweak

# 2. 修改 Makefile 中的设备 IP
# THEOS_DEVICE_IP = 你的越狱设备IP

# 3. 编译并安装
make package install
```

## Frida 监控脚本使用

```bash
# 确保设备已越狱并安装 Frida Server
# 通过 USB 连接设备

frida -U -f com.taobao.fleamarket -l scripts/xianyu_push_monitor.js --no-pause
```

监控脚本会实时输出以下关键数据：
- DeviceToken 上报过程
- UTDID 生成值
- ACCS Bind App / Bind User 参数
- 网络状态变化
- AGOO 消息接收
- Keychain 访问记录
- Kick Out 控制命令

## 多开打包建议

### 方案 A：修改 Bundle ID（需验证 SecurityGuard）

1. 使用轻松签/爱思修改 Bundle ID 重签
2. 测试登录和聊天功能是否正常
3. 如正常，直接注入本 Tweak

### 方案 B：保留 Bundle ID（推荐）

1. 使用多开工具的"应用分身"功能
2. **关闭** "修改 Bundle ID" 选项
3. **开启** "独立沙盒 (Data目录隔离)" 选项
4. **修改** "应用显示名称" 以便区分
5. 注入本 Tweak

## 核心模块详解

### 1. UTDID 离散化

```objc
%hook UTDIDIphoneSDK
+ (NSString *)getUtdid {
    // 官方原版放行
    // 多开分身基于 Bundle ID 哈希生成 24 位 Base64 标识
}
%end
```

### 2. 音频脉冲保活

```objc
void ExecuteAudioCpuPulse() {
    // 内存生成静音流 -> 激活 AVAudioSession -> 播放 0.05 秒 -> 停止
    // 25 秒周期，在 iOS 挂起临界点前精准保活
}
```

### 3. Keychain 绕过

```objc
%hookf(OSStatus, SecItemAdd, ...) {
    // 移除 kSecAttrAccessGroup，使用默认沙盒 Keychain
}
```

### 4. Kick Out 拦截

```objc
%hook TBSDKPushControlCmd
- (void)parseControlCommand:(NSDictionary *)commandDict {
    // 检测 kickout / duplicate_login 指令并直接返回
}
%end
```

## 技术架构

```
服务端推送
    ├── APNs ──> PKPushRegistry (原版) / 空集合 (多开)
    └── ACCS 长连接 ──> AccsVirtualSocket
              ├── UTDID 离散化 -> 独立 ClientID
              ├── Keychain 绕过 -> 正常读取凭证
              ├── Kick Out 拦截 -> 维持长连接
              └── 音频脉冲 -> 后台保活
```

## 注意事项

- 本 Tweak 仅供学习和研究使用
- 音频保活方案可能触发 iOS 高耗电警告
- 建议在越狱设备上充分测试后再部署
- 闲鱼版本更新可能导致类名变化，需适配

## 许可证

MIT License

## 作者

[jasonlima153](https://github.com/jasonlima153)