---
title: 从一次磁盘写满排查学 Linux 命令：df、du、findmnt 与 systemd 工具集
date: 2026-07-13 11:00:00 +0800
categories:
  - Linux
tags:
  - Linux
  - 命令行
  - systemd
  - Docker
---

在上一篇[《PVE 虚拟机 Bootdisk 被写满：从 NAS 挂载失效的排查，到自动化检测方案》](/2026/07/13/pve-nas-transmission-bootdisk-troubleshooting/)中，一次完整的排查用到了不少 Linux 命令。这些命令单独看都不复杂，但组合起来能定位一类相当隐蔽的问题——挂载点下被遮住的文件。本文把这些命令按使用场景整理出来，每个命令说明三件事：它做什么、排查中那条参数为什么这样写、还有哪些常用变体。

## 一、磁盘空间分析：df、du、sort、lsof

磁盘空间问题的排查基本都从这一组命令开始。它们回答的问题层层递进：**整体用了多少 → 具体在哪个目录 → 找不到时去哪找**。

### df —— 文件系统视角的使用量

`df`（disk free）按**文件系统**统计空间，数据来自文件系统自身的元数据，反映的是"块设备上实际被分配了多少"。

```bash
df -hT /
```

- `-h`：human-readable，用 GB/MB 显示，代替默认的 KB 块数；
- `-T`：额外显示文件系统类型（`ext4`、`cifs`、`overlay`……）；
- 最后的 `/`：只看根文件系统所在的那一行，不加则列出全部挂载。

排查中 `-T` 很关键：一眼确认某个路径当前落在本地盘还是网络文件系统上。

### du —— 目录视角的使用量

`du`（disk usage）**逐个文件累加**统计目录大小，反映的是"当前目录树能看见的文件加起来有多大"。

```bash
du -xhd1 / | sort -h
```

- `-x`：不跨越文件系统边界。统计 `/` 时不会把挂载在下面的 NAS、`/boot` 等算进来——对比 `df` 时必须加这个参数，否则两边口径不一致；
- `-h`：human-readable；
- `-d1`：只显示到第 1 层子目录（等价于 `--max-depth=1`），先看大方向，再逐层深入；
- `| sort -h`：按人类可读的数值排序，最大的目录排在最后。

逐层下钻的用法就是换目录重复执行：

```bash
du -xhd1 /var | sort -h
du -xhd1 /var/lib/docker | sort -h
```

### df 与 du 的差值是排查的核心信号

两个命令的统计口径不同，正常情况下结果接近；出现明显差值时，只有两种已知解释：

1. **文件已删除但仍被进程打开**——文件系统还没回收这些块，`df` 算得到，`du` 看不到；
2. **文件被挂载点遮住**——文件在本地盘上，但当前路径被另一个文件系统挂载覆盖，`du` 遍历不到。

这也是为什么"`df` 大、`du` 小"这个现象本身就是有效线索，而不是工具误差。

### sort -h —— 按人类可读数值排序

`sort -h`（`--human-numeric-sort`）能正确比较 `512K`、`36G`、`9.2G` 这类带单位的数值。如果用普通的 `sort -n`，`9.2G` 会排在 `36G` 后面（只比较数字部分），结果就乱了。凡是管道上游用了 `-h` 输出的命令（`du -h`、`df -h`），排序就配 `sort -h`。

### lsof +L1 —— 找出"已删除但仍被占用"的文件

`lsof` 列出系统中所有被进程打开的文件。`+L1` 表示只显示**硬链接数小于 1** 的文件——也就是目录树里已经没有名字、但还有进程持有句柄的文件，正对应上面的第一种解释。

```bash
lsof +L1
```

输出里重点看 `SIZE/OFF` 列（逻辑大小）和 `NAME` 列结尾的 `(deleted)` 标记。找到后，重启持有该文件的进程即可释放空间。

一个容易误判的点：`/memfd:* (deleted)` 这类条目是**内存文件**（`memfd_create` 创建的匿名内存对象），显示的大小不对应磁盘占用，统计缺口时应排除。

## 二、挂载管理：mount、umount、findmnt

这次排查的根因在挂载状态上，这一组命令负责查看和操作挂载。

### findmnt —— 查询挂载状态的首选工具

`findmnt` 比传统的 `mount`（无参数列出所有挂载）输出更结构化，且支持按路径反查。

```bash
findmnt /mnt/nas_media
```

查询这个路径**本身**是不是挂载点。是则输出来源设备和文件系统类型，不是则无输出——适合脚本判断。

```bash
findmnt -T /mnt/nas_media/temp/downloads
```

- `-T`（`--target`）：查询这个路径**所属**的文件系统。和上面不同，路径本身不必是挂载点，`findmnt` 会向上找到管辖它的那个挂载。判断"某个目录的写入最终落到哪里"用的就是它。

脚本中还用到了机器可读的形式：

```bash
findmnt -rn -T /mnt/nas_media -o FSTYPE
```

- `-r`：raw 输出，去掉树状装饰符；
- `-n`：不输出表头；
- `-o FSTYPE`：只输出文件系统类型这一列。

三个参数配合，输出就是干净的一个词（如 `cifs`），可以直接用于条件判断：

```bash
[ "$(findmnt -rn -T /mnt/nas_media -o FSTYPE)" = cifs ]
```

### mount / umount —— 挂载与卸载

```bash
mount /mnt/nas_media
```

只给一个路径时，`mount` 会去 `/etc/fstab` 里查这个挂载点对应的配置（设备、类型、选项）并执行挂载。这也是为什么网络挂载建议统一由 fstab 管理：命令行、开机自动挂载、systemd mount 单元用的都是同一份配置。

fstab 中网络文件系统常用的两个选项：

- `_netdev`：声明该挂载依赖网络，systemd 会把它安排在网络就绪之后；
- `nofail`：挂载失败不阻塞启动流程，避免 NAS 不在线时系统卡在启动。

```bash
umount /mnt/nas_media
```

正常卸载。如果有进程正在使用该目录，`umount` 会报 `target is busy` 并拒绝执行——这是保护，不是障碍。正确做法是先停掉相关进程（排查中是 `docker stop transmission`）再卸载。

要特别避免 `umount -l`（lazy 卸载）：它把挂载点立刻从目录树摘除，但等使用者全部退出才真正卸载，会制造出"看起来卸载了、实际还没有"的中间状态，排查时反而掩盖真实情况。

## 三、容器相关：docker 命令的排查用法

严格说这些不是 Linux 基础命令，但容器化部署下排查绕不开它们，且用法有共通的模式。

### docker inspect —— 查看容器的真实配置

```bash
docker inspect transmission \
  --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
```

`docker inspect` 默认输出整个 JSON，信息太多。`--format` 接受 Go template 语法做提取：`.Mounts` 是挂载数组，`range` 遍历，`println` 逐行打印宿主机路径（`.Source`）到容器内路径（`.Destination`）的映射。

排查的原则是**看运行时的真实状态，而不是看 compose 文件**——容器实际挂了什么，以 `inspect` 输出为准。

### docker exec —— 进入容器视角验证

```bash
docker exec transmission df -hT /downloads /nas_media/TVShow / /config
docker exec transmission grep -E 'download-dir|incomplete-dir' /config/settings.json
```

`docker exec <容器> <命令>` 在容器的命名空间里执行命令。这一步的意义是：宿主机看到的路径和容器内进程看到的路径是两套，配置文件（如 Transmission 的 `settings.json`）里写的是**容器内路径**，必须进容器验证才有意义。

`grep -E` 启用扩展正则，`download-dir|incomplete-dir` 中的 `|` 表示"或"，一条命令匹配两个配置项。

### docker stop / start / update —— 控制容器生命周期

```bash
docker stop -t 30 transmission     # 给 30 秒优雅退出时间，超时才强杀
docker start transmission
docker update --restart=no transmission
```

`docker update --restart` 在线修改容器的重启策略。排查方案中把它设为 `no`，是为了把启动权完全交给 systemd——否则 Docker 的 `unless-stopped` 策略会绕过 systemd 把容器拉起来。恢复时再设回 `unless-stopped`。

### docker system df —— Docker 自身的空间占用

```bash
docker system df -v
```

按镜像、容器可写层、数据卷、构建缓存分类统计 Docker 的磁盘占用，`-v` 细化到每个对象。排查磁盘问题时用它确认或排除"Docker 占了空间"这个方向。

## 四、systemd 工具集：systemctl、journalctl、systemd-escape

自动化方案完全构建在 systemd 上，用到的命令覆盖了服务管理的常见操作。

### systemctl —— 服务管理的主入口

方案中出现的子命令，按用途分组：

```bash
# 状态查看
systemctl status transmission-nas.service nas-guard.timer   # 详细状态，可一次查多个单元
systemctl is-active --quiet transmission-nas.service        # 只返回退出码，专供脚本判断
systemctl cat mnt-nas_media.mount                            # 查看单元文件内容及其来源路径

# 启停与开机自启
systemctl start transmission-nas.service
systemctl stop transmission-nas.service
systemctl enable --now transmission-nas.service    # enable(开机自启) + start(立即启动) 一步完成
systemctl disable --now nas-guard.timer            # 对应的反操作

# 维护
systemctl daemon-reload    # 修改/增删 /etc/systemd/system 下的单元文件后必须执行
systemctl reset-failed     # 清除单元的 failed 状态记录
```

几个值得单独记的点：

- `is-active --quiet`：不输出任何内容，服务运行中返回 0，否则非 0。写脚本条件判断时用它，不要去 grep `status` 的输出；
- `enable --now`：没有 `--now` 时 `enable` 只登记开机自启、不影响当前状态，两者容易混淆；
- `daemon-reload`：systemd 不会自动感知单元文件的修改，改完不 reload，改动不生效。

### journalctl —— 查询 systemd 日志

```bash
journalctl -t nas-guard
```

`-t`（`--identifier`）按日志标签过滤。这个标签正是脚本里 `logger -t nas-guard` 写入时打上的——写入和查询用同一个标识串起来。

其他高频用法：

```bash
journalctl -u transmission-nas.service   # 按 systemd 单元过滤
journalctl -f                            # 实时跟踪，类似 tail -f
journalctl --since "1 hour ago"          # 按时间过滤
```

### systemd-escape —— 路径与单元名的转换

systemd 为每个挂载点自动生成同名的 `.mount` 单元，但路径里的 `/` 要按规则转义。手工转换容易出错，用工具：

```bash
systemd-escape -p --suffix=mount /mnt/nas_media
# 输出: mnt-nas_media.mount
```

- `-p`：按路径规则转义（去掉首尾 `/`，中间的 `/` 变 `-`，特殊字符变 `\x` 编码）；
- `--suffix=mount`：追加单元后缀。

拿到单元名后，就可以在其他单元里写 `Requires=`、`BindsTo=` 依赖，或直接 `systemctl status mnt-nas_media.mount` 查看挂载单元状态。

### 附：方案中用到的单元依赖指令

这几个不是命令，是单元文件里的指令，但值得放在一起记：

| 指令 | 语义 |
|---|---|
| `Requires=` | 强依赖：依赖的单元启动失败，本单元不启动 |
| `After=` | 只定顺序：本单元在其之后启动（不隐含依赖，需与 Requires 搭配） |
| `BindsTo=` | 比 Requires 更强：被依赖单元**停止**时，本单元跟着停止 |
| `Wants=` | 弱依赖：尽量一起启动，失败也不影响本单元 |

`Requires` + `After` + `BindsTo` 的组合，实现的就是"挂载不在则不启动、挂载消失则跟着停"。

## 五、脚本工具箱：写健壮 Shell 脚本用到的小命令

[安装脚本](/assets/scripts/install-transmission-nas-guard.sh)里还有一批小工具，单个都很简单，但都是写系统脚本的常客。

### timeout —— 给命令加最长执行时间

```bash
timeout 5 /bin/bash -c 'echo >/dev/tcp/192.168.50.2/445'
```

`timeout 5 <命令>`：命令 5 秒内没结束就强制终止，返回非 0。对一切可能卡住的网络操作，都应该套一层 `timeout`，否则一次 NAS 无响应就能挂起整个检测脚本。

### /dev/tcp —— Bash 内建的端口连通性测试

`/dev/tcp/<主机>/<端口>` 不是真实文件，是 **Bash 的内建特性**：对它做重定向时，Bash 会尝试建立 TCP 连接，成功返回 0，失败返回非 0。

```bash
echo >/dev/tcp/192.168.50.2/445 && echo "端口可达"
```

优点是零依赖——不需要安装 `nc`、`nmap`。注意两点：必须用 `bash` 执行（`sh`/`dash` 不支持，所以脚本里显式写了 `/bin/bash -c`）；它只验证 TCP 握手成功，不验证端口后面的服务是否真正可用。

### logger —— 从脚本写入系统日志

```bash
logger -t nas-guard "NAS unavailable; stopping transmission"
```

把一行消息写进 syslog/journal，`-t` 指定标签。脚本用 `logger` 而不是 `echo` 到自建日志文件的好处：日志进入系统统一管理（轮转、持久化、时间戳），查询时 `journalctl -t nas-guard` 一条命令搞定。

### command -v —— 检查命令是否存在

```bash
command -v docker >/dev/null || { echo "missing docker"; exit 1; }
```

`command -v` 输出命令的路径，找不到则返回非 0。脚本开头逐个检查依赖命令，比运行到一半才报 `command not found` 友好得多。判断命令是否存在用它，不要用 `which`（非 POSIX 标准，行为因发行版而异）。

### chmod +x 与 mkdir -p

```bash
chmod +x install-transmission-nas-guard.sh   # 赋予执行权限
mkdir -p /mnt/nas_media                       # 逐级创建目录；已存在时静默成功，不报错
```

`mkdir -p` 的"已存在不报错"特性使它是幂等的，脚本里可以放心重复执行。

### set -Eeuo pipefail —— 脚本的安全开关

安装脚本第一行的选项组合，含义是让脚本"遇错即停"：

- `-e`：任何命令失败（非 0 退出）立即终止脚本；
- `-u`：引用未定义变量视为错误；
- `-o pipefail`：管道中任何一环失败，整个管道视为失败（默认只看最后一个命令）；
- `-E`：让 `ERR` 陷阱在函数和子 shell 中也生效。

对会修改系统状态的脚本（装单元文件、改容器配置），这组开关能避免"前一步失败、后面照常执行"造成的半成品状态。

## 六、场景速查表

| 想解决的问题 | 命令 |
|---|---|
| 磁盘整体用了多少 | `df -hT /` |
| 空间被哪个目录占了 | `du -xhd1 <目录> \| sort -h` |
| df 和 du 对不上：查已删除文件 | `lsof +L1` |
| df 和 du 对不上：查被遮住的文件 | 停进程 → `umount` → `du` 挂载点 |
| 某路径的写入落在哪个文件系统 | `findmnt -T <路径>` |
| 脚本中判断挂载类型 | `findmnt -rn -T <路径> -o FSTYPE` |
| 容器实际挂载了什么 | `docker inspect <容器> --format ...` |
| 容器内视角验证路径 | `docker exec <容器> df -hT ...` |
| Docker 自身占了多少空间 | `docker system df -v` |
| 测试远端端口连通性（零依赖） | `timeout 5 bash -c 'echo >/dev/tcp/<主机>/<端口>'` |
| 脚本写系统日志 / 查这些日志 | `logger -t <标签>` / `journalctl -t <标签>` |
| 路径转 systemd 挂载单元名 | `systemd-escape -p --suffix=mount <路径>` |
| 改完单元文件不生效 | `systemctl daemon-reload` |

## 结语

这份清单里没有生僻命令，价值在于组合方式：`df` 与 `du` 的口径差异本身就是线索，`findmnt -T` 回答"写入到底落在哪"，`lsof +L1` 与"卸载后再看"分别对应差值的两种成因，systemd 的依赖指令则把人工规程固化为系统行为。命令是零件，排查思路才是图纸——建议配合[上一篇的完整排查过程](/2026/07/13/pve-nas-transmission-bootdisk-troubleshooting/)一起看。
