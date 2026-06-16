// ============================================================================
// XianYu Push Monitor - Frida Dynamic Interception Script
// 用途：动态抓取多开环境下的 DeviceToken、UTDID、ACCS ClientID 等关键参数
// 使用方法：frida -U -f com.taobao.fleamarket -l xianyu_push_monitor.js --no-pause
// ============================================================================

if (ObjC.available) {
    console.log('[*] XianYu Push Monitor Started');
    console.log('[*] Target Bundle ID: com.taobao.fleamarket');
    console.log('[*] Monitoring: DeviceToken, ACCS Bind, Network Status, AGOO Messages');
    console.log('============================================================');

    // 1. 监控 DeviceToken 上报
    try {
        var deviceTokenMgr = ObjC.classes.ALBBDeviceTokenManager;
        Interceptor.attach(deviceTokenMgr['- uploadDeviceToken'].implementation, {
            onEnter: function(args) {
                console.log('[DeviceToken] Upload triggered');
                console.log('[DeviceToken] Instance:', this);
            },
            onLeave: function(retval) {
                console.log('[DeviceToken] Upload completed, retval:', retval);
            }
        });
        
        // 监控 deviceTokenKey / deviceTokenSign / deviceTokenSalt
        var keys = ['deviceTokenKey', 'deviceTokenSign', 'deviceTokenSalt'];
        keys.forEach(function(key) {
            var sel = ObjC.selector(key);
            if (deviceTokenMgr[sel]) {
                Interceptor.attach(deviceTokenMgr[sel].implementation, {
                    onLeave: function(retval) {
                        console.log('[Identity]', key + ':', ObjC.Object(retval).toString());
                    }
                });
            }
        });
        console.log('[+] ALBBDeviceTokenManager hooked');
    } catch(e) { 
        console.log('[!] ALBBDeviceTokenManager not found:', e.message); 
    }

    // 2. 监控 UTDID 获取
    try {
        var utdidClass = ObjC.classes.UTDIDIphoneSDK;
        Interceptor.attach(utdidClass['+ getUtdid'].implementation, {
            onLeave: function(retval) {
                console.log('[UTDID] Value:', ObjC.Object(retval).toString());
            }
        });
        console.log('[+] UTDIDIphoneSDK hooked');
    } catch(e) { 
        console.log('[!] UTDIDIphoneSDK not found:', e.message); 
    }

    // 3. 监控 ACCS 绑定流程
    try {
        var accsMgr = ObjC.classes.TBAccsManager;
        Interceptor.attach(accsMgr['- bindAppWithAppKey:ttid:appVersion:'].implementation, {
            onEnter: function(args) {
                console.log('[ACCS] === Bind App ===');
                console.log('[ACCS] appKey:', ObjC.Object(args[2]).toString());
                console.log('[ACCS] ttid:', ObjC.Object(args[3]).toString());
                console.log('[ACCS] appVersion:', ObjC.Object(args[4]).toString());
            }
        });
        Interceptor.attach(accsMgr['- bindUserWithUserId:token:'].implementation, {
            onEnter: function(args) {
                console.log('[ACCS] === Bind User ===');
                console.log('[ACCS] userId:', ObjC.Object(args[2]).toString());
                console.log('[ACCS] token:', ObjC.Object(args[3]).toString());
            }
        });
        console.log('[+] TBAccsManager hooked');
    } catch(e) { 
        console.log('[!] TBAccsManager not found:', e.message); 
    }

    // 4. 监控网络状态变化
    try {
        var accsSocket = ObjC.classes.AccsVirtualSocket;
        Interceptor.attach(accsSocket['- OnNetworkStatusChanged:'].implementation, {
            onEnter: function(args) {
                console.log('[ACCS] Network Status Changed, status code:', args[2]);
            }
        });
        console.log('[+] AccsVirtualSocket hooked');
    } catch(e) { 
        console.log('[!] AccsVirtualSocket not found:', e.message); 
    }

    // 5. 监控 AGOO 消息接收
    try {
        var agooMsg = ObjC.classes.TBSDKAgooMessage;
        Interceptor.attach(agooMsg['- onReceiveAgooMessage:withError:'].implementation, {
            onEnter: function(args) {
                console.log('[AGOO] Message received');
                console.log('[AGOO] Message object:', ObjC.Object(args[2]).toString());
            }
        });
        console.log('[+] TBSDKAgooMessage hooked');
    } catch(e) { 
        console.log('[!] TBSDKAgooMessage not found:', e.message); 
    }

    // 6. 监控 Keychain 访问
    try {
        var SecItemAdd = Module.findExportByName('Security', 'SecItemAdd');
        Interceptor.attach(SecItemAdd, {
            onEnter: function(args) {
                var query = ObjC.Object(args[0]);
                var accessGroup = query.objectForKey_('agrp');
                if (accessGroup) {
                    console.log('[Keychain] SecItemAdd accessGroup:', accessGroup.toString());
                }
                var service = query.objectForKey_('svce');
                if (service) {
                    console.log('[Keychain] SecItemAdd service:', service.toString());
                }
            }
        });
        
        var SecItemCopyMatching = Module.findExportByName('Security', 'SecItemCopyMatching');
        Interceptor.attach(SecItemCopyMatching, {
            onEnter: function(args) {
                var query = ObjC.Object(args[0]);
                var accessGroup = query.objectForKey_('agrp');
                if (accessGroup) {
                    console.log('[Keychain] SecItemCopyMatching accessGroup:', accessGroup.toString());
                }
            }
        });
        console.log('[+] Keychain hooks installed');
    } catch(e) { 
        console.log('[!] Keychain hooks failed:', e.message); 
    }

    // 7. 监控 Kick Out 控制命令
    try {
        var pushControl = ObjC.classes.TBSDKPushControlCmd;
        Interceptor.attach(pushControl['- parseControlCommand:'].implementation, {
            onEnter: function(args) {
                var cmdDict = ObjC.Object(args[2]);
                if (cmdDict) {
                    console.log('[KickOut] Control command received:', cmdDict.toString());
                }
            }
        });
        console.log('[+] TBSDKPushControlCmd hooked');
    } catch(e) { 
        console.log('[!] TBSDKPushControlCmd not found:', e.message); 
    }

    console.log('============================================================');
    console.log('[*] All hooks installed. Waiting for events...');
} else {
    console.log('[!] Objective-C runtime not available');
}