# 热点省电 · Hotspot Power Saver

关热点时关射频、降频、关核心、关蓝牙，熄屏后深度休眠，开热点恢复

*Radio, CPU and Bluetooth off while the hotspot is off, and deep sleep with the screen dark*

容悦 E5（OpenWrt）信息屏应用。当前版本 **v2.5**，应用 ID `hotspotdata`。

## 截图

<img src="screenshots/hotspot-saver.png" alt="热点省电" width="320">

设备屏幕上的热点省电页面：省电开关、热点、移动数据、蜂窝、CPU / GPU、蓝牙、熄屏刷新、CPU 核心和后台服务的当前状态。

![各状态平均功率](screenshots/power-by-state.jpg)

用[功率监测](https://github.com/CharlesGool/e5-powermon)实测：熄屏、热点开、省电未生效时平均 1455 mW（满电约 8.4 小时）；熄屏、热点关、省电生效时平均 332 mW（满电约 37.4 小时）。

## 安装

1. 下载 [`releases/hotspotdata-v2.5.tar.gz`](releases/hotspotdata-v2.5.tar.gz)。
2. 在信息屏的「应用管理」中安装（LuCI：服务 → 信息屏应用 → 应用管理）。
3. 安装后文件位于设备上的 `/etc/e5-infoscreen/plugins/hotspotdata/`。

## 设置

加粗为默认值。

- 启用热点省电（Hotspot power saving）：默认开
- 关热点时（With the hotspot off）：**关闭蜂窝（最省电，收不到短信电话）**；只断数据（短信电话正常）
- 射频关闭时暂停 SIM 状态轮询（Pause SIM polling while radio is off）：默认开  
  <sub>更省电；期间状态栏不显示运营商</sub>
- 关热点时 CPU / GPU 锁最低频率（Lowest CPU / GPU clocks with the hotspot off）：默认开  
  <sub>开热点时恢复；期间屏幕操作会变慢</sub>
- 关热点时关闭 CPU 核心（CPU cores with the hotspot off）：**只留小核**；只留 2 个小核；全部保留  
  <sub>开热点时全部恢复；若关核心导致死机，下次开机自动改回全部保留</sub>
- 屏幕亮着时临时恢复全速（Full speed while the screen is lit）：默认开  
  <sub>亮屏 1 秒内放开核心和频率，熄屏 5 秒后恢复限制</sub>
- 熄屏时暂停屏幕电源监视（Pause the screen power watcher while dark）：默认开  
  <sub>熄屏 5 秒后暂停每秒 10 次的背光检查，亮屏后恢复</sub>
- 无设备连接时自动关热点（分钟）（Hotspot off when unused (min)）：0–120 min，默认 30  
  <sub>0 为不自动关；USB 连着电脑时不关</sub>
- 关热点时关闭蓝牙（Bluetooth off with the hotspot）：默认开  
  <sub>有蓝牙设备连着时不关；开热点时恢复</sub>
- 关热点后深度休眠（Deep sleep with the hotspot off）：默认开  
  <sub>熄屏后系统真正休眠，按键、充电器、基带唤醒；插着 USB 或充电时不休眠</sub>
- 熄屏后多久开始休眠（秒）：5–600，默认 30
- 蜂窝射频开着时也休眠：默认关  
  <sub>默认只在射频关闭后休眠；射频开着时基带每隔几秒唤醒一次，反复醒睡可能比不睡更费电</sub>
- 唤醒后保持清醒（秒）：2–60，默认 5  
  <sub>基带唤醒（短信、来电）时至少 15 秒</sub>
- 休眠时定时唤醒（分钟）：0–240，默认 0
- 射频关闭时熄屏刷新间隔（Dark-screen refresh with the radio off）：5 秒（原样）；30 秒；**1 分钟**；5 分钟
- 关热点后延迟断开（分钟）（Delay after hotspot off (min)）：0–30 min，默认 0

## 深度休眠

OpenWrt 从不让内核休眠：熄屏只是背光为 0，SoC 一直醒着。内核和固件其实支持
（`/sys/power/mem_sleep` 有 `deep`），`sleep.sh`（同一服务的 `sleep` 实例）在下面几条
都满足时让系统挂起到内存，被无关事件唤醒后很快再睡回去：

- 熄屏达到设定时间；
- 热点关闭：Wi-Fi 驱动休眠时会停掉 AP，hostapd 不知道，热点会坏；
- 没插 USB、没充电：USB 驱动有 VBUS 时拒绝休眠；
- 蜂窝射频已关闭（或打开了“射频开着时也休眠”）；
- 没有声音在播放或录音，没有 `/sys/power/wake_lock` 唤醒锁。

连续 3 次睡不到 10 秒会暂缓休眠（60 秒起，加倍，最多 10 分钟）。

实测（关热点、射频关、熄屏、拔线）：152.9 秒里睡了 148.6 秒（97%）；电源键唤醒并点亮屏幕。
射频和数据开着时只睡 17.6%，平均 147 mA，比不睡（74 mA）更费电，所以默认只在射频关闭后休眠。

主线内核的 PMIC 看门狗驱动（`ump9620-pmic-wdt`）没有挂起处理，休眠时照样计时，procd 被冻结
无法喂狗，睡满 30 秒就会复位并回退进 Android。所以每次休眠前让 procd 用 magic close 关闭看门狗，
醒来立刻重新打开。

休眠会让 CLOCK_MONOTONIC 停走、/proc/uptime 照走：系统的 t551m-sim-status 用前者给 SIM 状态
打时间戳，状态栏和本应用用后者判断新旧，休眠过一次后信号就一直显示“状态未知”、蜂窝“读取中”。
本应用会把 t551m-sim-status 和 t551m-registration 改成 CLOCK_BOOTTIME（镜像更新后自动重做）。

已知限制：侧键长按（sidekey）在休眠中可能被识别成单击（唤醒约需 1 秒）；每次唤醒内核会把
显示面板重新上电一次。日志：`logread -e hotspotdata | grep sleep:`。

## 源码

`hotspotdata/` 是当前版本安装包解压后的内容：

- [`backend.uc`](hotspotdata/backend.uc)
- [`hotspot-data.init`](hotspotdata/hotspot-data.init)
- [`index.html`](hotspotdata/index.html)
- [`manifest.json`](hotspotdata/manifest.json)
- [`poll-patch.js`](hotspotdata/poll-patch.js)
- [`service.sh`](hotspotdata/service.sh)
- [`sleep.sh`](hotspotdata/sleep.sh)

## 版本

- [v2.5](releases/hotspotdata-v2.5.tar.gz)（当前）：关热点后深度休眠；修复休眠后信号显示“状态未知”
- [v2.3](releases/hotspotdata-v2.3.tar.gz)
- [v2.2](releases/hotspotdata-v2.2.tar.gz)
- [v2.1](releases/hotspotdata-v2.1.tar.gz)
- [v2.0](releases/hotspotdata-v2.0.tar.gz)
- [v1.9](releases/hotspotdata-v1.9.tar.gz)
- [v1.8](releases/hotspotdata-v1.8.tar.gz)
- [v1.7](releases/hotspotdata-v1.7.tar.gz)
- [v1.5](releases/hotspotdata-v1.5.tar.gz)
- [v1.4](releases/hotspotdata-v1.4.tar.gz)
- [v1.3](releases/hotspotdata-v1.3.tar.gz)
- [v1.2](releases/hotspotdata-v1.2.tar.gz)
- [v1.1](releases/hotspotdata-v1.1.tar.gz)
- [v1.0](releases/hotspotdata-v1.0.tar.gz)
