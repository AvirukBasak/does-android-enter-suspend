# Does Android Enter Suspend Mode?

**TL;DR**: Mine does not. So you don't need to hold a partial wakelock on termux for long running tasks.
Just using unrestricted battery is enough to prevent `deep-idle` from halting your process group.

## Device & ROM

- Redmi Note 9 Pro (India): Miatoll/Curtana
- ROM: Evolution X 11.4.1 (Android 16)
- Android Security Update: Nov 1, 2025
- Vendor Security Patch Level: May 1, 2023
- Build number: `miatoll-userdebug 16 BP2A.250805.005 2 release-keys`

```
getprop ro.build.description:     curtana_in1-user 12 RKQ1.211019.001 V14.0.5.0.SJWINRF release-keys
getprop ro.build.fingerprint:     Redmi/curtana_in1/curtana:12/RKQ1.211019.001/V14.0.5.0.SJWINRF:user/release-keys
getprop ro.build.version.release: 16
getprop ro.build.flavor:          miatoll-userdebug
```

## Kernel
```
uname -a
uname -r
```

Returns:
```
Linux localhost 4.14.356-openela-rc1 nexus/ecca9d6c #1 SMP PREEMPT Thu Dec 4 01:26:38 CET 2025 aarch64 Android
4.14.356-openela-rc1 nexus/ecca9d6c
```


## Experiment

- Termux did not hold a wakelock
- Left device connected via ADB overnight
- Disabled battery using `dumpsys battery unplug` (affects Android, not the kernel or h/w, so device keeps charging).
- Device kept cycling between `deep-idle` doze mode and `deep-maint` maintenance modes normally (increasing windows).
- Ran the script with `nohup sudo ./test_cpuwork.sh & disown` to test kernel C-state and Suspend-2-RAM behaviors.
- Results have been run through Claude Sonnet 4.6 coz IDK Android much.
- Chances are Sonnet 4.6 assumes a lot of the behaviors so take em with a grain of salt.

## Observations

### 1. Only C0 is active, C1 and C2 are zero throughout
Sonnet 4.6 says:
> `c1_usage`, `c2_usage`, `c1_time_us`, `c2_time_us` are all **zero** for every row. This means the CPU never entered
> the deeper power-collapse or retention states (C1/C2 on this Qualcomm SoC). Only the shallow WFI
> ("wait-for-interrupt") idle, C0, is being used.

### 2. C0 is firing ~1.43–1.48 million times per hour, with ~2.3 ms average residence
Sonnet 4.6 says:
> Each C0 entry is extremely short, the CPU wakes, does a tiny bit of work, and immediately goes back to WFI. This is
> the normal heartbeat of a Linux kernel even when "idle", scheduler ticks, timer interrupts, etc.

### 3. C0 accounts for ~93% of wall time
Sonnet 4.6 says:
> The `c0_time_us` fraction of wall-clock time stabilises at **~0.936–0.937** after the first interval. So the CPU is
> genuinely idle (in WFI) ~93% of the time, healthy for a screen-off device.

### 4. suspend_stats success/fail is 0 the entire run
Sonnet 4.6 says:
> This is the smoking gun. **The device never suspended once** across the ~9-hour run. Without a wakelock held
> (as you noted), this must mean something else was keeping the system awake.

### 5. Idling history:
```
 deep-idle: -10h22m23s
deep-maint: -9h22m23s   ← maintenance window
 deep-idle: -9h21m53s
deep-maint: -7h21m53s   ← maintenance window
 deep-idle: -7h21m23s
deep-maint: -3h21m23s   ← maintenance window
 deep-idle: -3h20m53s   ← still here at dump time
```

Sonnet 4.6 says:
> Doze **was** cycling in and out of deep-idle and maintenance windows correctly. But `mState=IDLE mLightState=OVERRIDE`
> with `mNetworkConnected=true` means the light-idle state was overridden (likely because of the active network
> connection), and — critically — **Doze deep-idle does not equal system suspend on all devices**. On this Qualcomm
> platform, Doze can enter its own "deep idle" state while the kernel remains running (no S2R suspend), which is exactly
> what you're seeing: `suspend_stats/success` stays zero.

### 6. The hash never changes
Sonnet 4.6 says:
> `9ed44503afca5aed99a0f7c85de21144` is identical in every row — `find /proc/self -maxdepth 1` always returns the same
> result set, confirming Termux's process environment was completely stable throughout.

---

## Conclusions
- Did the device actually suspend (S2R)? No, coz suspend_stats is 0.
- Can kernel auto-suspend? Also no. Apparently, it's upto Android to initiate suspend, which it did not.
- Was CPU genuinely idle? Likely, and was using interrupts to wake up for brief periods.
- Did deeper CPU idle states (C1/C2) engage? Clearly, it did not. IDK why.
- Did Android's doze work? Yes. However, `deep-idle` doesn't map one-one to kernel suspend.
- Was a wakelock the culprit? Maybe, only if something other than Termux is holding a partial wakelock.

Sonnet 4.6 says:
> The takeaway: on this device (likely Qualcomm + LineageOS based on `org.lineageos.dspvolume.xiaomi` in the whitelist),
> Doze deep-idle and kernel suspend are **decoupled**. The CPU idles very efficiently in C0 WFI (~93%) but never reaches
> the power-collapse/retention states that would show up as C1/C2 entries or suspend_stats increments.

---

## Enabling Suspend-2-RAM

### Find out supported power states:
```
sudo cat /sys/power/state
```

Returns `freeze` and `mem`.
- `freeze`: Suspend-to-Idle, Equivalent to: `mem_sleep = s2idle`. CPUs are put into their deepest idle state (C-states)
- `mem`: Suspend-to-RAM (S3-like). Equivalent to: `mem_sleep = deep`. All CPUs are powered off, most SoC subsystems
  (GPU, display, peripherals) are powered off, RAM stays powered in self-refresh mode.

Others (unsopported):
- `standby`: Power-On Suspend (S1/S2-like). Equivalent to: `mem_sleep = shallow`. Non-boot CPUs are hotplugged off
  (taken offline). CPU0 enters a deeper sleep. RAM is still powered and self-refreshing. Some peripheral clocks may
  be gated off.
- `disk`: Suspend-to-Disk (Hibernation / S4). The entire RAM contents are serialized and written to a swap partition or
  file. Then the system fully powers off, RAM loses power too. Android likely doesn't have a swap.

### Find out supported `mem_sleep` states:

```
sudo cat /sys/power/mem_sleep
```

Returns:

```
[s2idle] deep
```

Which means Suspend-to-Idle is active and Suspend-to-RAM is not.

### Enter suspend

We need to first change `mem_sleep` state to `deep`. This changes the output to `s2idle [deep]`.
```
echo deep | sudo tee /sys/power/mem_sleep
```

NOTE: Shell `>` fails coz they run as user and not root.

Then we can enter suspend using:
```
echo mem | sudo tee /sys/power/state
```

### Failure

From shell:
```
mem
tee: /sys/power/state: Device or resource busy
```

From DMESG (ignore all `ibat_ua` from battery discharge):
```
[46309.560173] (elapsed 0.009 seconds) done.
[46309.566794] (elapsed 0.006 seconds) done.
[46309.576272] msm-dwc3 a600000.ssusb: Abort PM suspend!! (USB is outside LPM)
[46309.576304] dpm_run_callback(): platform_pm_suspend+0x0/0x60 returns -16
[46309.576320] PM: Device a600000.ssusb failed to suspend: error -16
[46309.592826] done.
[46309.597235] Abort: Callback failed on a600000.ssusb in platform_pm_suspend+0x0/0x60 returned -16
```

### What this means?

```
msm-dwc3 a600000.ssusb: Abort PM suspend!! (USB is outside LPM)
PM: Device a600000.ssusb failed to suspend: error -16
```

- `msm-dwc3`: Qualcomm’s USB3 controller driver (we’re on a Miatoll, so Snapdragon 720G).
- `USB is outside LPM`: USB is not in Low Power Mode, it’s still active.
- `error -16` is `-EBUSY`, the driver explicitly refused to suspend.
- The entire suspend chain aborts because one driver returning error cancels everything.

### Fix

Schedule suspend in 10 seconds as a root process:
```
sudo sh -c 'sleep 10 && echo mem > /sys/power/state' & disown $!
```

Disconnect USB:
```
[46348.431172] [PMIC_DEBUG][usb_plugin_irq_handler]: pd_hard_reset=0
[46348.432040] ibat_ua =-253296
[46348.436256] RNDIS_IPA NetDev pipes disconnected (1 outstanding clr)
[46348.436285] ipa ipa3_get_ep_mapping:4250 Bad client number! client =1885953896
[46348.436549] ipa ipa3_set_client:4336 Bad client number! client =0
[46348.436562] ipa ipa3_set_client:4336 Bad client number! client =0
[46348.439126] ibat_ua =-253296
[46348.441142] pm6150_charger: smblib_set_icl_current: set icl current = 100000
[46348.441719] pm6150_charger: smblib_set_icl_current: set icl current = 100000
[46348.447526] usbpd usbpd0: USB Type-C disconnect
[46348.450557] android_work: sent uevent USB_STATE=DISCONNECTED
```

This turns of Ethernet over USB in my case as well, so:
```
[46348.616113] RNDIS_IPA NetDev queue is stopped
[46348.631911] rmnet_perf_config_notify_cb(): rmnet_perf netdevice unregister, name = rndis0
[46348.671429] RNDIS_IPA NetDev was cleaned
[46348.673155] read descriptors
[46348.673172] read strings
[46348.684313] msm-dwc3 a600000.ssusb: ep [gsi-epin14,29] already configured as msm endpoint
[46348.684337] msm-dwc3 a600000.ssusb: ep [gsi-epout15,30] already configured as msm endpoint
[46348.696963] rmnet_perf_config_notify_cb(): rmnet_perf netdevice register, name = rndis0
[46348.700212] RNDIS_IPA NetDev was initialized
[46348.701263] android_work: did not send uevent (0 0 0000000000000000)
```

And after 10 seconds this shows up. Observe that:

- Screen went off and then came on within a few seconds without any interaction.
- The DMESG says `Resume cause unknown`.
- Unlock worked via fingerprint scanner but touch did not work. I had to turn the screen on and off.
- Novatek Touchscreen Driver (nvt-ts / NVT-ts): returns `firmware: novatek_ts_tianma_fw.bin will not be loaded` and
  `[NVT-ts] update_firmware_request 320: firmware load failed, ret=-11`
- UFS Storage Stack (SCSI): returns a bunch of `runtime PM trying to activate child device ... but parent (...)
  is not active`.
- Second suspend attempt resulted in a reboot.
- So, suspend works, but it seems to be buggy.

```
[46354.536246] (elapsed 0.005 seconds) done.
[46354.542410] (elapsed 0.006 seconds) done.
[46354.558090] spi_geni a94000.spi: spi_geni_suspend: Force suspend
[46354.837342] Disabling non-boot CPUs ...
[46354.877073] suspend ns:   46354877050415	suspend cycles:     890253162744
[46354.877050] resume cycles:     890565817892
[46354.877529] Enabling non-boot CPUs ...
[46354.906569] scsi host0: runtime PM trying to activate child device host0 but parent (1d84000.ufshc) is not active
[46354.906619] scsi target0:0:0: runtime PM trying to activate child device target0:0:0 but parent (host0) is not active
[46354.906943] scsi 0:0:0:49476: runtime PM trying to activate child device 0:0:0:49476 but parent (target0:0:0) is not active
[46354.907026] scsi 0:0:0:49456: runtime PM trying to activate child device 0:0:0:49456 but parent (target0:0:0) is not active
[46354.907116] dsi-ctrl:[_dsi_ctrl_setup_isr] [DSI_0] IRQ 426 registered
[46354.907342] scsi 0:0:0:49488: runtime PM trying to activate child device 0:0:0:49488 but parent (target0:0:0) is not active
[46354.920950] sd 0:0:0:4: runtime PM trying to activate child device 0:0:0:4 but parent (target0:0:0) is not active
[46354.920966] sd 0:0:0:1: runtime PM trying to activate child device 0:0:0:1 but parent (target0:0:0) is not active
[46354.927538] sd 0:0:0:5: runtime PM trying to activate child device 0:0:0:5 but parent (target0:0:0) is not active
[46354.927583] sd 0:0:0:3: runtime PM trying to activate child device 0:0:0:3 but parent (target0:0:0) is not active
[46354.927633] sd 0:0:0:2: runtime PM trying to activate child device 0:0:0:2 but parent (target0:0:0) is not active
[46354.927677] sd 0:0:0:0: runtime PM trying to activate child device 0:0:0:0 but parent (target0:0:0) is not active
[46355.053902] ------------[ cut here ]------------
[46355.053936] WARNING: CPU: 5 PID: 26775 at ../../../../../../kernel/xiaomi/sm6250/drivers/base/firmware_class.c:1108 _request_firmware.llvm.16865427985910018990+0x668/0xa00
[46355.053950] CPU: 5 PID: 26775 Comm: kworker/u16:10 Tainted: G S      W       4.14.356-openela-rc1 nexus/ecca9d6c #1
[46355.053956] Hardware name: Qualcomm Technologies, Inc. ATOLL-AB PM6150 wcd937x Audio Codec AB IDP CURTANA (DT)
[46355.053978] Workqueue: nvt_ts_workqueue nvt_ts_resume_work
[46355.053990] task: 000000006ad22a3d task.stack: 00000000381180f8
[46355.053998] pc : _request_firmware.llvm.16865427985910018990+0x668/0xa00
[46355.054007] lr : _request_firmware.llvm.16865427985910018990+0x660/0xa00
[46355.054012] sp : ffffff801166bc50 pstate : 60c00005
[46355.054017] x29: ffffff801166bc70 x28: 0000000000000005 
[46355.054027] x27: 000000007fffffff x26: 0000000000004650 
[46355.054037] x25: fffffff7717eb000 x24: 00000000fffffff5 
[46355.054046] x23: fffffff7b542d8d9 x22: ffffff9f2ce54000 
[46355.054055] x21: 0000000000000005 x20: fffffff771763700 
[46355.054065] x19: ffffff9f2d1a5100 x18: 0000000000000000 
[46355.054073] x17: 0000000000000000 x16: ffffffffffffffff 
[46355.054083] x15: 0000000000000018 x14: 0000000000010000 
[46355.054092] x13: dead000000000100 x12: ffffff9f2ce99400 
[46355.054101] x11: ffffff9f2ce99400 x10: 0000000000000000 
[46355.054110] x9 : fffffff7728ad100 x8 : 0000000000000020 
[46355.054119] x7 : 0000000000000000 x6 : 6d7269662f62696c 
[46355.054128] x5 : 007764000062696c x4 : ffffffbfddc5fa10 
[46355.054137] x3 : ffffff9f2ce99400 x2 : ffffff801166bbf0 
[46355.054147] x1 : ffffff801166bbf0 x0 : 00000000fffffff5 
[46355.054163] 
               PC: _request_firmware.llvm.16865427985910018990+0x628/0xa00:
[46355.054167] 2fe8  14000004 12800178 2a1503fc 361019b5 d000bd88 b94d1908 52802589 1b097d09
[46355.054199] 3008  93407d29 7100011f b27ff3e8 9a88c13a 3708017c 97e09121 340001a0 2a0003f8
[46355.054226] 3028  d4210000 90008501 91187021 f9400be0 aa1703e2 97ff40dd 140000d1 aa1a03e0
[46355.054253] 3048  97e0916e aa0003fa b40006c0 b0009de8 f947fd00 52901801 72a02801 97e6946f
[46355.054286] 
               LR: _request_firmware.llvm.16865427985910018990+0x620/0xa00:
[46355.054289] 2fe0  2a1503fc 36101a35 14000004 12800178 2a1503fc 361019b5 d000bd88 b94d1908
[46355.054317] 3000  52802589 1b097d09 93407d29 7100011f b27ff3e8 9a88c13a 3708017c 97e09121
[46355.054344] 3020  340001a0 2a0003f8 d4210000 90008501 91187021 f9400be0 aa1703e2 97ff40dd
[46355.054371] 3040  140000d1 aa1a03e0 97e0916e aa0003fa b40006c0 b0009de8 f947fd00 52901801
[46355.054414] 
               SP: 0xffffff801166bc10:
[46355.054417] bc10  2b6c3028 ffffff9f 60c00005 00000000 fffffffe 00000000 b542d8d9 fffffff7
[46355.054444] bc30  ffffffff ffffffff 00000005 00000000 1166bc70 ffffff80 2b6c3028 ffffff9f
[46355.054471] bc50  bfd59d80 fffffff7 728ad100 00000005 b5428800 fffffff7 2af2db88 ffffff9f
[46355.054498] bc70  1166bcf0 ffffff80 2b92252c ffffff9f 00000000 00000000 0000001c 00000000

[46355.054528] Call trace:
[46355.054538]  _request_firmware.llvm.16865427985910018990+0x668/0xa00
[46355.054545]  nvt_update_firmware+0xac/0x1450
[46355.054552]  nvt_ts_resume_work+0x3c/0x280
[46355.054565]  process_one_work+0x2e4/0x5a0
[46355.054572]  worker_thread+0x3bc/0xac0
[46355.054583]  kthread+0x288/0x2a0
[46355.054592]  ret_from_fork+0x10/0x18
[46355.054598] ---[ end trace 40f4ecd06c3b2c8d ]---
[46355.054673] NVT-ts spi1.0: firmware: novatek_ts_tianma_fw.bin will not be loaded
[46355.054688] [NVT-ts] update_firmware_request 320: firmware load failed, ret=-11
[46355.054903] ------------[ cut here ]------------
[46355.054918] WARNING: CPU: 5 PID: 26775 at ../../../../../../kernel/xiaomi/sm6250/drivers/base/firmware_class.c:1108 _request_firmware.llvm.16865427985910018990+0x668/0xa00
[46355.054927] CPU: 5 PID: 26775 Comm: kworker/u16:10 Tainted: G S      W       4.14.356-openela-rc1 nexus/ecca9d6c #1
[46355.054931] Hardware name: Qualcomm Technologies, Inc. ATOLL-AB PM6150 wcd937x Audio Codec AB IDP CURTANA (DT)
[46355.054941] Workqueue: nvt_ts_workqueue nvt_ts_resume_work
[46355.054950] task: 000000006ad22a3d task.stack: 00000000381180f8
[46355.054957] pc : _request_firmware.llvm.16865427985910018990+0x668/0xa00
[46355.054965] lr : _request_firmware.llvm.16865427985910018990+0x660/0xa00
[46355.054970] sp : ffffff801166bc50 pstate : 60c00005
[46355.054973] x29: ffffff801166bc70 x28: 0000000000000005 
[46355.054983] x27: 000000007fffffff x26: 0000000000004650 
[46355.054991] x25: fffffff7b15bd000 x24: 00000000fffffff5 
[46355.055000] x23: fffffff7b542d8d9 x22: ffffff9f2ce54000 
[46355.055009] x21: 0000000000000005 x20: fffffff771763700 
[46355.055017] x19: ffffff9f2d1a5100 x18: 0000000000000000 
[46355.055025] x17: 0000000000000000 x16: ffffffffffffffff 
[46355.055034] x15: 0000000000000018 x14: 0000000000010000 
[46355.055043] x13: dead000000000100 x12: ffffff9f2ce99400 
[46355.055051] x11: ffffff9f2ce99400 x10: 0000000000000000 
[46355.055059] x9 : fffffff7728ad100 x8 : 0000000000000020 
[46355.055068] x7 : 0000000000000000 x6 : 6d7269662f62696c 
[46355.055076] x5 : 007764000062696c x4 : ffffffbfdec56e10 
[46355.055084] x3 : ffffff9f2ce99400 x2 : ffffff801166bbf0 
[46355.055093] x1 : ffffff801166bbf0 x0 : 00000000fffffff5 
[46355.055108] 
               PC: _request_firmware.llvm.16865427985910018990+0x628/0xa00:
[46355.055111] 2fe8  14000004 12800178 2a1503fc 361019b5 d000bd88 b94d1908 52802589 1b097d09
[46355.055137] 3008  93407d29 7100011f b27ff3e8 9a88c13a 3708017c 97e09121 340001a0 2a0003f8
[46355.055163] 3028  d4210000 90008501 91187021 f9400be0 aa1703e2 97ff40dd 140000d1 aa1a03e0
[46355.055188] 3048  97e0916e aa0003fa b40006c0 b0009de8 f947fd00 52901801 72a02801 97e6946f
[46355.055219] 
               LR: _request_firmware.llvm.16865427985910018990+0x620/0xa00:
[46355.055222] 2fe0  2a1503fc 36101a35 14000004 12800178 2a1503fc 361019b5 d000bd88 b94d1908
[46355.055247] 3000  52802589 1b097d09 93407d29 7100011f b27ff3e8 9a88c13a 3708017c 97e09121
[46355.055272] 3020  340001a0 2a0003f8 d4210000 90008501 91187021 f9400be0 aa1703e2 97ff40dd
[46355.055297] 3040  140000d1 aa1a03e0 97e0916e aa0003fa b40006c0 b0009de8 f947fd00 52901801
[46355.055327] 
               SP: 0xffffff801166bc10:
[46355.055329] bc10  2b6c3028 ffffff9f 60c00005 00000000 fffffffe 00000000 b542d8d9 fffffff7
[46355.055354] bc30  ffffffff ffffffff 00000005 00000000 1166bc70 ffffff80 2b6c3028 ffffff9f
[46355.055379] bc50  2c7cf5a2 ffffff9f 00000140 00000005 b5428800 fffffff7 00000020 00000000
[46355.055404] bc70  1166bcf0 ffffff80 2b92252c ffffff9f 00000001 00000000 0000001c 00000000

[46355.055431] Call trace:
[46355.055439]  _request_firmware.llvm.16865427985910018990+0x668/0xa00
[46355.055446]  nvt_update_firmware+0xac/0x1450
[46355.055453]  nvt_ts_resume_work+0x3c/0x280
[46355.055460]  process_one_work+0x2e4/0x5a0
[46355.055466]  worker_thread+0x3bc/0xac0
[46355.055474]  kthread+0x288/0x2a0
[46355.055480]  ret_from_fork+0x10/0x18
[46355.055485] ---[ end trace 40f4ecd06c3b2c8e ]---
[46355.055493] NVT-ts spi1.0: firmware: novatek_ts_tianma_fw.bin will not be loaded
[46355.055502] [NVT-ts] update_firmware_request 320: firmware load failed, ret=-11
[46355.055703] ------------[ cut here ]------------
[46355.055718] WARNING: CPU: 5 PID: 26775 at ../../../../../../kernel/xiaomi/sm6250/drivers/base/firmware_class.c:1108 _request_firmware.llvm.16865427985910018990+0x668/0xa00
[46355.055727] CPU: 5 PID: 26775 Comm: kworker/u16:10 Tainted: G S      W       4.14.356-openela-rc1 nexus/ecca9d6c #1
[46355.055731] Hardware name: Qualcomm Technologies, Inc. ATOLL-AB PM6150 wcd937x Audio Codec AB IDP CURTANA (DT)
[46355.055740] Workqueue: nvt_ts_workqueue nvt_ts_resume_work
[46355.055749] task: 000000006ad22a3d task.stack: 00000000381180f8
[46355.055756] pc : _request_firmware.llvm.16865427985910018990+0x668/0xa00
[46355.055764] lr : _request_firmware.llvm.16865427985910018990+0x660/0xa00
[46355.055768] sp : ffffff801166bc50 pstate : 60c00005
[46355.055772] x29: ffffff801166bc70 x28: 0000000000000005 
[46355.055781] x27: 000000007fffffff x26: 0000000000004650 
[46355.055789] x25: fffffff7717eb000 x24: 00000000fffffff5 
[46355.055798] x23: fffffff7b542d8d9 x22: ffffff9f2ce54000 
[46355.055806] x21: 0000000000000005 x20: fffffff771763700 
[46355.055815] x19: ffffff9f2d1a5100 x18: 0000000000000000 
[46355.055823] x17: 0000000000000000 x16: ffffffffffffffff 
[46355.055832] x15: 0000000000000018 x14: 0000000000010000 
[46355.055840] x13: dead000000000100 x12: ffffff9f2ce99400 
[46355.055849] x11: ffffff9f2ce99400 x10: 0000000000000000 
[46355.055857] x9 : fffffff7728ad100 x8 : 0000000000000020 
[46355.055865] x7 : 0000000000000000 x6 : 6d7269662f62696c 
[46355.055874] x5 : 007764000062696c x4 : ffffffbfddc5fa10 
[46355.055882] x3 : ffffff9f2ce99400 x2 : ffffff801166bbf0 
[46355.055891] x1 : ffffff801166bbf0 x0 : 00000000fffffff5 
[46355.055905] 
               PC: _request_firmware.llvm.16865427985910018990+0x628/0xa00:
[46355.055907] 2fe8  14000004 12800178 2a1503fc 361019b5 d000bd88 b94d1908 52802589 1b097d09
[46355.055933] 3008  93407d29 7100011f b27ff3e8 9a88c13a 3708017c 97e09121 340001a0 2a0003f8
[46355.055958] 3028  d4210000 90008501 91187021 f9400be0 aa1703e2 97ff40dd 140000d1 aa1a03e0
[46355.055983] 3048  97e0916e aa0003fa b40006c0 b0009de8 f947fd00 52901801 72a02801 97e6946f
[46355.056014] 
               LR: _request_firmware.llvm.16865427985910018990+0x620/0xa00:
[46355.056016] 2fe0  2a1503fc 36101a35 14000004 12800178 2a1503fc 361019b5 d000bd88 b94d1908
[46355.056041] 3000  52802589 1b097d09 93407d29 7100011f b27ff3e8 9a88c13a 3708017c 97e09121
[46355.056066] 3020  340001a0 2a0003f8 d4210000 90008501 91187021 f9400be0 aa1703e2 97ff40dd
[46355.056092] 3040  140000d1 aa1a03e0 97e0916e aa0003fa b40006c0 b0009de8 f947fd00 52901801
[46355.056121] 
               SP: 0xffffff801166bc10:
[46355.056124] bc10  2b6c3028 ffffff9f 60c00005 00000000 fffffffe 00000000 b542d8d9 fffffff7
[46355.056149] bc30  ffffffff ffffffff 00000005 00000000 1166bc70 ffffff80 2b6c3028 ffffff9f
[46355.056173] bc50  2c7cf5a2 ffffff9f 00000140 00000005 b5428800 fffffff7 00000020 00000000
[46355.056198] bc70  1166bcf0 ffffff80 2b92252c ffffff9f 00000002 00000000 0000001c 00000000

[46355.056225] Call trace:
[46355.056233]  _request_firmware.llvm.16865427985910018990+0x668/0xa00
[46355.056241]  nvt_update_firmware+0xac/0x1450
[46355.056247]  nvt_ts_resume_work+0x3c/0x280
[46355.056254]  process_one_work+0x2e4/0x5a0
[46355.056261]  worker_thread+0x3bc/0xac0
[46355.056268]  kthread+0x288/0x2a0
[46355.056275]  ret_from_fork+0x10/0x18
[46355.056279] ---[ end trace 40f4ecd06c3b2c8f ]---
[46355.056287] NVT-ts spi1.0: firmware: novatek_ts_tianma_fw.bin will not be loaded
[46355.056296] [NVT-ts] update_firmware_request 320: firmware load failed, ret=-11
[46355.056302] [NVT-ts] update_firmware_request 358: error, retry=3
[46355.056308] [NVT-ts] nvt_update_firmware 889: update_firmware_request failed. (-11)
[46355.056314] [NVT-ts] nvt_ts_resume 2395: download firmware failed, ignore check fw state
[46355.062910] done.
[46355.067022] Resume cause unknown
```

And this is after I connected USB
```
[46380.822968] [PMIC_DEBUG][usb_plugin_irq_handler]: pd_hard_reset=0
[46381.575292] pm6150_charger: smblib_set_icl_current: set icl current = 500000
[46381.580145] usbpd usbpd0: typec mode:6 type:4
[46381.638728] ibat_ua =-335388
[46381.803187] android_work: sent uevent USB_STATE=CONNECTED
[46381.807594] android_work: sent uevent USB_STATE=DISCONNECTED
[46381.925999] android_work: sent uevent USB_STATE=CONNECTED
[46381.935525] configfs-gadget gadget: high-speed config #1: b
[46381.936548] android_work: sent uevent USB_STATE=CONFIGURED
[46381.942356] RNDIS_IPA NetDev pipes were connected
[46381.943013] ipa ipa3_get_ep_mapping:4250 Bad client number! client =1885953896
[46381.943413] ipa ipa3_set_client:4338 Bad pipe index! index =-1
[46381.943425] ipa ipa3_set_client:4338 Bad pipe index! index =-1
[46381.980736] id0:ipa_usb_notify_cb: Set net_ready_trigger
[46381.980754] RNDIS_IPA NetDev was opened
[46396.830353] dsi-ctrl:[_dsi_ctrl_setup_isr] [DSI_0] IRQ 426 registered
```

And also
```
sudo cat /sys/power/suspend_stats/success
```

Returns a count of `1`.

---

## Finding the Wakelock Holder

Before we start, do note that C0/C1/C2 states are activated by the kernel automatically and the kernel can have the CPU
go in and out of the states based on interrupts. However, Suspend-2-RAM likely needs to be initiated from userspace.

### Step 1: Establish ground truth: did the kernel ever suspend?
```
sudo cat /sys/power/suspend_stats/success
```
Returned **0** across 9 hours. Device never suspended. This was the first hard signal something was wrong.

### Step 2: Rule out kernel-level wakelocks
```
sudo cat /sys/power/wake_lock
```
Returned **nothing**. No kernel (partial) wakelock held. Pushed the problem up to the Android layer.

### Step 3: Rule out driver rejection
```
sudo cat /sys/power/suspend_stats/failed_suspend
sudo cat /sys/power/suspend_stats/last_failed_dev
```
Returned **0** and **nothing** respectively. Not a driver vetoing suspend. Combined with step 1: Android **never even tried** to suspend. Problem is likely in PowerManager.

### Step 4: Check Android's power state

```
adb shell dumpsys power | grep -E "mWakefulness|mHoldingDisplaySuspendBlocker|mStayOn"
```

Returned:
```
  mWakefulness=Dozing
  mWakefulnessChanging=false
  mStayOn=false
  mHoldingDisplaySuspendBlocker=false
  mStayOnWhilePluggedInSetting=0
```
Of these, `mWakefulness=Dozing` and other flags false. Confirms that Android was in Doze but never handing off to kernel. Doze is further confirmed from `adb shell dumpsys deviceidle`:

Idling history:
```
      deep-idle: -10h22m23s371ms
     deep-maint: -9h22m23s364ms
      deep-idle: -9h21m53s309ms
     deep-maint: -7h21m53s298ms
      deep-idle: -7h21m23s247ms
     deep-maint: -3h21m23s242ms
      deep-idle: -3h20m53s158ms
```

Other flags:
```
  mLightEnabled=true
  mDeepEnabled=true
  mForceIdle=false
  mUseMotionSensor=true
  mMotionSensor={Sensor name="sns_smd  Wakeup", vendor="qualcomm", version=1, type=17, maxRange=1.0, resolution=1.0, power=0.025, minDelay=-1}
  mScreenOn=false
  mScreenLocked=true
  mNetworkConnected=true
  mCharging=false
  activeEmergencyCall=false
  mMotionActive=false
  mNotMoving=false
  mMotionListener.activatedTimeElapsed=0
  mLastMotionEventElapsed=0

  0 stationary listeners registered
  Location prefetching disabled

  mState=IDLE
  mLightState=OVERRIDE
  mInactiveTimeout=+15s0ms
  mNextAlarmTime=+2h39m6s841ms
  mNextIdlePendingDelay=+10m0s0ms
  mNextIdleDelay=+6h0m0s0ms
  mNextLightIdleDelay=+5m0s0ms (flex=+1m0s0ms)
  mCurLightIdleBudget=+1m0s0ms
  mMaintenanceStartTime=-3h21m23s242ms
```

### Step 5: Find the actual holder

```
adb shell dumpsys power | grep -A 10 "Wake Locks:"
```

Returned:
```
Wake Locks: size=1
  DOZE_WAKE_LOCK                    'dream:doze' ACQ=-10h51m29s812ms (uid=1000 pid=2135)

Suspend Blockers: size=5
  PowerManagerService.Booting: ref count=0 []
  PowerManagerService.WakeLocks: ref count=0 []
  PowerManagerService.Display: ref count=0 []
  PowerManagerService.Broadcasts: ref count=0 []
  PowerManagerService.WirelessChargerDetector: ref count=0 []

Display Power: com.android.server.power.PowerManagerService$1@ce9bf18

Battery saving stats:
  Battery Saver is currently: ON
    Last ON time: 2026-10-10 05:26:19.759 -11h1m30s719ms
    Times full enabled: 1
    Times adaptive enabled: 0
  
  Drain stats:
                     Battery saver OFF                          ON
  NonDoze NonIntr:      0m      0mAh(  0%)      0.0mAh/h          3m      0mAh(  0%)      0.0mAh/h
             Intr:      0m      0mAh(  0%)      0.0mAh/h         10m      0mAh(  0%)      0.0mAh/h
  Deep    NonIntr:      0m      0mAh(  0%)      0.0mAh/h        419m      0mAh(  0%)      0.0mAh/h
             Intr:      0m      0mAh(  0%)      0.0mAh/h          0m      0mAh(  0%)      0.0mAh/h
  Light   NonIntr:      0m      0mAh(  0%)      0.0mAh/h          0m      0mAh(  0%)      0.0mAh/h
             Intr:      0m      0mAh(  0%)      0.0mAh/h          0m      0mAh(  0%)      0.0mAh/h

Battery saver policy (*NOTE* they only apply when battery saver is ON):
  Settings: battery_saver_constants
    value: 
  Settings: (overlay)
```

Observe, **`DOZE_WAKE_LOCK 'dream:doze' ACQ=-10h51m uid=1000`** held the entire run, lkely by the Android system itself. Never released in the middle.

The output also showed `Suspend Blockers: size=5` with all at `ref count=0`. This is **not** a contradiction as those 5 are pre-registered structural slots in
PowerManagerService (Booting, WakeLocks, Display, Broadcasts, WirelessChargerDetector), declared at boot and sitting empty. `DOZE_WAKE_LOCK` is a different type,
acquired via `PowerManager.newWakeLock(DOZE_WAKE_LOCK)` and deliberately sits outside the suspend blocker accounting. So all 5 blockers at ref count=0 actually
**reinforced** that Android never initiated suspend: none of its own internal gates were raised, yet suspend never happened, meaning the blocker was somewhere
the normal accounting doesn't surface.

### Step 6: Find root cause
```
adb shell dumpsys deviceidle | grep -E "mNetworkConnected|mLightState|mState"
```

See the output in `Step 4`, `mNetworkConnected=true` and `mLightState=OVERRIDE`. Chances are (according to Claude Sonnet 4.6), doze was intentionally suppressing
suspend while network is active. But this has not been confirmed and needs further experiments.

### Note

To enable suspend, you can `echo mem > /sys/power/state` (or some other sysfs command).

---

## The kernel does not self-suspend

This is the core misconception worth clearing up. The kernel has no autonomous "I've been idle long enough, I'll suspend
now" logic. Android has to initiate it via **PowerManagerService**, (via a native thread called `SuspendThread` or
`autosuspend` thread in older HALs).

The ~93% C0 WFI the logs is the kernel idling between interrupts: that's automatic. But S2R requires a deliberate
userspace action.

```
Kernel idle loop (C0 WFI)   ←  kernel does this autonomously
        ≠
Kernel suspend (S2R / mem)  ←  requires userspace to explicitly trigger it
```

### The gate sequence PowerManagerService uses

If (and this is conjecture at this point), for suspend to happen, PMS works through this chain internally:

```
1. mWakefulness == Asleep (not Dozing, not Awake)
        AND
2. All suspend blockers at ref count=0
        AND
3. No DOZE_WAKE_LOCK held (i.e. Doze dream not in control)
        AND
4. wakeup_count handshake succeeds (race-free suspend check)
        │
        ▼
   autosuspend thread writes "mem" → /sys/power/state
        │
        ▼
   Kernel enters S2R
```

Then in our case however, Gate 3 failed as `DOZE_WAKE_LOCK` was held for 11 hours, keeping `mWakefulness=Dozing` instead
of transitioning to `Asleep`. PMS's autosuspend thread never got a green light to write to `/sys/power/state`, i.e. the
kernel was never asked to suspend.

### Why Android did not suspend?

We can only guess, but `mNetworkConnected=true` is a plausible contributing factor as network connectivity is known to
affect Doze behaviour.

