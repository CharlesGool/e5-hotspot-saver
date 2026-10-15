# 热点省电 · Hotspot Power Saver

关热点时关射频、降频、关核心、关蓝牙，开热点恢复

*Radio, CPU and Bluetooth off while the hotspot is off*

容悦 E5（OpenWrt）信息屏应用。当前版本 **v2.3**，应用 ID `hotspotdata`。

## 安装

1. 下载 [`releases/hotspotdata-v2.3.tar.gz`](releases/hotspotdata-v2.3.tar.gz)。
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
- 射频关闭时熄屏刷新间隔（Dark-screen refresh with the radio off）：5 秒（原样）；30 秒；**1 分钟**；5 分钟
- 关热点后延迟断开（分钟）（Delay after hotspot off (min)）：0–30 min，默认 0

## 源码

`hotspotdata/` 是当前版本安装包解压后的内容：

- [`backend.uc`](hotspotdata/backend.uc)
- [`hotspot-data.init`](hotspotdata/hotspot-data.init)
- [`index.html`](hotspotdata/index.html)
- [`manifest.json`](hotspotdata/manifest.json)
- [`poll-patch.js`](hotspotdata/poll-patch.js)
- [`service.sh`](hotspotdata/service.sh)

## 版本

- [v2.3](releases/hotspotdata-v2.3.tar.gz)（当前）
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
