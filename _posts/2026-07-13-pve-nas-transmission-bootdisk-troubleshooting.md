---
title: PVE 虚拟机 Bootdisk 被写满：从 NAS 挂载失效的排查，到自动化检测方案
date: 2026-07-13 10:00:00
categories:
  - Linux
  - PVE
tags:
  - PVE
  - NAS
  - Docker
  - Transmission
---

## 问题现象

环境是一个常见的家庭服务器组合：PVE 上运行 Debian 虚拟机，虚拟机内用 Docker 部署 Transmission，下载目录通过 CIFS 挂载到局域网 NAS：

```text
NAS:       //192.168.50.2/Multimedia
虚拟机:    /mnt/nas_media
容器:      /nas_media
下载目录:  /nas_media/TVShow
```

按设计，虚拟机的 Bootdisk 只保存系统、容器和配置文件，占用应该基本稳定。实际观察到的现象是：Bootdisk 使用量持续增长，直到接近写满，并且伴随一个反常的特征：

```text
df 显示根文件系统已使用大量空间
du 却找不到对应体积的目录
```

Transmission 的下载目录配置没有改过，Docker 日志体积也在正常范围内。本文记录这次排查的完整过程：问题最终定位在 NAS 挂载失效上；而由于这类失效随时可能再次发生，排查结束后又引出了一套自动化检测方案。

## 排查过程

### 第一步：确认容器的实际写入路径

先确认 Transmission 容器的 volume 映射，排除"下载目录本来就配在本地"的可能：

```bash
docker inspect transmission \
  --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
```

输出显示映射关系符合预期：

```text
/mnt/nas_media/temp/downloads -> /downloads
/mnt/nas_media                -> /nas_media
/docker/transmission/config   -> /config
```

再确认 Transmission 自身的配置。注意 `settings.json` 中使用的是容器内路径，不是宿主机路径：

```bash
docker exec transmission \
  grep -E 'download-dir|incomplete-dir' /config/settings.json
```

```json
{
  "download-dir": "/nas_media/TVShow",
  "incomplete-dir": "/downloads/incomplete",
  "incomplete-dir-enabled": false
}
```

下载目录指向 NAS 路径，未完成目录功能关闭。到这里可以确认：路径映射和下载配置都没有问题。

然后检查宿主机和容器内对应路径的文件系统类型：

```bash
findmnt -T /mnt/nas_media/temp/downloads
docker exec transmission df -hT /downloads /nas_media/TVShow / /config
```

正常状态下，`/downloads` 和 `/nas_media/TVShow` 应显示为 `cifs`，根目录和配置目录则是本地的 `ext4` 或 Docker 的 `overlay`。这次检查时挂载状态是正常的——这也说明问题不在"当前"，而可能发生在过去某个时间段。

### 第二步：对比 `df` 与 `du`

```bash
df -hT /
du -xhd1 / | sort -h
```

`du -x` 不跨越文件系统边界，因此不会把 NAS 上的数据统计进来。结果是 `df` 报告的使用量明显大于 `du` 能解释的部分，差额有几十 GB。

`df` 与 `du` 不一致，一般有两个已知方向：

1. 文件已被删除，但仍被某个进程持有，空间未释放；
2. 文件位于某个挂载点下面，被当前的挂载"遮住"，`du` 统计不到。

### 第三步：排除"已删除但被占用"的文件

```bash
lsof +L1
```

输出中确实有一些 `(deleted)` 条目，但需要逐项判断。例如 Jellyfin 产生的 `/memfd:* (deleted)` 是内存映射对象，其显示的逻辑大小并不对应等量的磁盘占用，不能直接计入差额。排除这些后，剩余的已删除文件不足以解释几十 GB 的缺口。

顺带检查 Docker 和自定义数据目录，同样没有异常增长：

```bash
du -xhd1 /var | sort -h
du -xhd1 /var/lib/docker | sort -h
du -xhd1 /docker | sort -h
docker system df -v
```

至此只剩下第二个方向：挂载点下面藏着本地文件。

### 第四步：卸载挂载点，检查被遮住的文件

这一步需要先停止会访问该目录的容器，再正常卸载（不要用 `umount -l` 等强制方式，否则可能掩盖真实状态）：

```bash
docker stop transmission
umount /mnt/nas_media
du -xhd1 /mnt/nas_media | sort -h
```

卸载后看到的才是虚拟机本地根盘上的真实内容。这次排查的实际结果：

```text
4.0G  /mnt/nas_media/Movie
9.2G  /mnt/nas_media/TVShow
36G   /mnt/nas_media/temp
49G   /mnt/nas_media
```

49 GB 的本地文件，与 `df`、`du` 之间的差额基本吻合。问题定位完成。

## 根因分析：挂载失效后，挂载点退化成本地目录

这个现象背后的机制并不复杂，但容易被忽略：**挂载不是目录的永久属性**。

NAS 正常挂载时，`/mnt/nas_media` 下的读写由 CIFS 文件系统处理，数据写到 NAS。但当挂载失败、被卸载，或系统启动时挂载未成功，`/mnt/nas_media` 这个目录仍然存在——只是变回了根盘上的一个普通本地目录。Transmission 感知不到这个变化，仍按原路径继续写入，数据就全部落在 Bootdisk 上。

之后 NAS 重新挂载，NAS 的目录树会把本地目录"盖住"。之前写到本地的文件没有消失，只是暂时不可见——这正是 `df` 统计得到、`du` 统计不到的原因。

需要说明的是，网络中断并不必然导致数据回退到本地，关键在于挂载是否还存在：

```text
网络断开，但 CIFS 仍处于挂载状态：写入会阻塞、重试或报 I/O 错误，数据不会落到本地
CIFS 已卸载或挂载失败：路径退化为本地目录，程序继续写入 Bootdisk，且不会报任何错误
```

两种状态中，后者才是真正的风险来源：它没有任何报错，下载器运行"正常"，唯一的外部表现就是本地磁盘持续增长。

## 清理本地文件

确认这批文件不再需要后，必须在 NAS 尚未重新挂载时清理。如果在 NAS 挂回之后对同一路径执行删除，删掉的会是 NAS 上的真实数据。

清理完成后重新挂载，确认文件系统类型，再启动容器：

```bash
mkdir -p /mnt/nas_media
mount /mnt/nas_media
findmnt /mnt/nas_media
docker start transmission
```

## 为什么需要自动化检测

到这里，问题本身已经解决，但有三个事实决定了它大概率会复发：

1. **触发条件不可控。** NAS 重启、交换机断电、虚拟机启动顺序早于 NAS 就绪、CIFS 会话异常，任何一个都可能让挂载消失。这些事件无法从虚拟机侧杜绝。
2. **故障是静默的。** 挂载消失后没有任何报错，Transmission 照常下载、照常做种。等到人工发现 `df` 异常时，往往已经写入了几十 GB。
3. **人工检查不可持续。** 依靠定期登录执行 `findmnt` 或 `df`，本质上是把监控交给记忆力，检查间隔也远大于"故障发生到磁盘写满"的时间窗口。

因此，合理的目标不是"保证挂载永不失效"——这做不到；而是：**在挂载失效时尽快停止下载器，并留下日志记录**。把一个静默的、后果持续累积的故障，转化为一个可检测、可停止、可追溯的服务状态。

## 自动化检测方案

针对"一个 NAS 挂载点对应一个 Docker Transmission 容器"的场景，方案分为两层：

1. 用 systemd 把 Transmission 的生命周期绑定到 NAS 挂载单元——挂载单元停止时，容器随之停止；
2. 用 systemd timer 周期性主动检测 CIFS 挂载状态和 NAS 的 SMB 服务可达性——覆盖挂载单元自身感知不到的异常。

### 第一层：让服务生命周期依赖挂载状态

安装脚本会创建 `transmission-nas.service`，核心依赖关系如下：

```ini
[Unit]
Wants=network-online.target
Requires=docker.service mnt-nas_media.mount
After=network-online.target docker.service mnt-nas_media.mount
BindsTo=mnt-nas_media.mount
```

systemd 会把 `/mnt/nas_media` 路径转换为对应的 `mnt-nas_media.mount` 单元（脚本内部用 `systemd-escape` 完成转换）。`Requires` 和 `After` 保证服务启动前挂载已就绪；`BindsTo` 则保证挂载单元停止时，Transmission 服务同步停止。

服务启动前还会显式校验目标路径的文件系统类型确实是 CIFS，防止"目录存在但挂载不在"的状态通过检查：

```ini
ExecStartPre=/bin/sh -c '[ "$(findmnt -rn -T /mnt/nas_media -o FSTYPE)" = cifs ]'
ExecStart=/usr/bin/docker start transmission
ExecStop=-/usr/bin/docker stop -t 30 transmission
```

为了避免 Docker 的重启策略绕过 systemd 把容器重新拉起，安装脚本会关闭容器原有的自动重启：

```bash
docker update --restart=no transmission
```

此后 Transmission 的唯一启动入口是 systemd 服务，而不是 Docker 的 `unless-stopped` 策略。

### 第二层：定时检测挂载和 SMB 服务

第一层依赖 systemd 对挂载单元状态的感知，但某些异常（例如挂载名义上存在、NAS 实际已不可达）不一定会及时反映到挂载单元上。因此安装脚本会再部署一个检测脚本 `/usr/local/sbin/transmission-nas-guard`，由 systemd timer 周期性触发，每次检查两件事：

```text
挂载点的文件系统类型是否仍为 cifs
NAS 的 TCP 445 端口是否可达（5 秒超时）
```

两项都通过时不做任何操作；任一项失败且服务仍在运行时，通过 `logger -t nas-guard` 记录日志，并停止 `transmission-nas.service`。检查间隔默认 30 秒，可在安装时调整。

### 安装前提

安装脚本在执行前会做一系列校验，不满足会直接退出：

- 以 root 执行；
- `/mnt/nas_media` 当前必须已挂载且类型为 `cifs`——即安装动作要在 NAS 状态正常时进行；
- 该挂载点必须由 `/etc/fstab` 管理（存在对应的 systemd mount 单元），否则会提示先配置 fstab；
- 目标 Docker 容器必须存在；
- 系统需具备 `docker`、`findmnt`、`systemctl`、`systemd-escape`、`timeout`、`logger` 等命令。

### 安装与使用

```bash
chmod +x install-transmission-nas-guard.sh
sudo ./install-transmission-nas-guard.sh \
  /mnt/nas_media 192.168.50.2 transmission 30
```

四个参数依次是：挂载路径、NAS 地址、Docker 容器名、检查间隔（秒），均有默认值。脚本会创建三个 systemd 单元并立即启用：

```text
transmission-nas.service  按挂载状态启动和停止容器
nas-guard.service         执行一次检测
nas-guard.timer           周期性触发检测
```

安装完成时，脚本会先停止容器、关闭其 Docker 重启策略，再通过 `systemctl enable --now` 由 systemd 重新接管启动——也就是说，安装动作本身会重启一次 Transmission。

日常查看运行状态和历史停止记录：

```bash
systemctl status transmission-nas.service nas-guard.timer
journalctl -t nas-guard
```

NAS 故障恢复后，方案不会自动重启容器。这是有意的设计：自动重启需要判断"挂载已真正恢复且指向正确的共享"，误判的代价是再次写入本地。因此恢复流程保留人工确认这一步：

```bash
findmnt /mnt/nas_media
systemctl start transmission-nas.service
```

## 方案边界

这套方案解决的是"挂载失效后继续写本地磁盘"这一个具体问题，不是完整的存储一致性系统。使用时需要明确以下边界：

- CIFS 挂载建议在 `/etc/fstab` 中使用 `_netdev,nofail` 等适合网络文件系统的选项；
- 检测条件固定为"文件系统类型是 `cifs` + TCP 445 可达"；使用 NFS、其他端口或其他挂载方式时需要修改脚本；
- TCP 445 可达只说明 SMB 服务端口有响应，不等于共享目录可读写，也不等于挂载的是正确的共享；
- 检测存在时间窗口：从挂载失效到定时器下一次触发之间（默认最长 30 秒），写入仍可能落到本地；
- 脚本不会搬运或删除挂载失效期间产生的本地文件，清理仍需人工按前文流程操作；
- 方案不替代 NAS 本身的备份、权限管理和磁盘容量监控。

如果不再需要这套保护，执行卸载脚本即可：

```bash
chmod +x uninstall-transmission-nas-guard.sh
sudo ./uninstall-transmission-nas-guard.sh
```

卸载脚本只停用并删除它创建的 systemd 单元和检测脚本，不卸载 NAS，也不删除下载数据。执行后 Transmission 保持停止状态；如需恢复 Docker 的自动启动，再显式执行：

```bash
docker start transmission
docker update --restart=unless-stopped transmission
```

## 总结

这次排查的结论可以概括为一条链路：NAS 挂载在某个时刻失效，挂载点退化为 Bootdisk 上的普通目录；Transmission 无感知地继续写入；NAS 重新挂载后本地文件被遮住，最终表现为 `df` 与 `du` 不一致、磁盘持续增长。

排查方法上，遇到类似现象时的检查顺序是：先确认容器路径映射和文件系统类型，再对比 `df` 与 `du`，用 `lsof +L1` 排除已删除文件，最后停止容器、卸载挂载点，检查被遮住的本地内容。

而由于这类故障静默、可复发、依赖人工巡检不现实，一次性的清理并不算真正解决问题。把 Transmission 的生命周期绑定到挂载单元，再辅以周期性的挂载和服务检测，才能把这个静默累积的故障变成可检测、可停止、可记录的服务状态——这是本文方案的实际价值，也是它的能力边界。
