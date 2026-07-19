# CC Switch Node 修复工具

![平台](https://img.shields.io/badge/平台-macOS-black) ![协议](https://img.shields.io/badge/协议-MIT-blue)

CC Switch 突然弹出 `env: node: No such file or directory`？跑一下这个脚本，它会自动修好，并装好"自动防护"——以后复发也不用你管。

> 你不需要是程序员，全程复制粘贴即可。

## 你遇到的是这个吗？

打开 CC Switch 时看到下面任意一种情况，这个工具就是给你用的：

- 报错：`env: node: No such file or directory`
- 诊断提示：「重复安装」

## 怎么用（30 秒）

1. 打开「终端」（启动台里搜"终端"）。
2. 粘贴下面这行，回车：

```bash
cd ~/Downloads && git clone https://github.com/reroc8/ccswitch-node-fix.git && cd ccswitch-node-fix && ./fix-ccswitch-node.sh
```

如果你已经把脚本放在某个文件夹，直接进那个文件夹运行：

```bash
cd 脚本所在文件夹 && ./fix-ccswitch-node.sh
```

中途若提示输入密码，输入开机密码即可（屏幕不显示字符，正常）。

预期输出（节选）：

```
[✓] 符号链接就绪: v24.18.0
[✓] LaunchAgent 已安装并注入 PATH
[✓] 看门狗已安装（每 5 分钟自检）
[✓] CC Switch 已重启
```

## 它能帮你解决什么

- **报错 `env: node`** — CC Switch 找不到 node。脚本把 node 放到系统能找到的地方，并让系统记住这个位置。
- **提示「重复安装」** — 电脑里装了多个 node，CC Switch 看到重复就报警。脚本只保留你正在用的那一份，清掉多余的。
- **复发** — 修完还可能偶尔再犯。脚本装了一个"看门狗"，每 5 分钟自动检查，发现问题自己重启，你不用管。

## 常用命令

| 命令 | 作用 |
| --- | --- |
| `./fix-ccswitch-node.sh` | 一键修复 + 装自动防护（推荐） |
| `./fix-ccswitch-node.sh --check` | 只检查，不改任何东西 |
| `./fix-ccswitch-node.sh --no-restart` | 修复但不重启（手动重启后生效） |
| `./fix-ccswitch-node.sh --uninstall-watchdog` | 卸载自动防护 |

重复运行脚本是安全的。

## 它做了什么（一句话）

把 node 放到系统能找到的地方、清掉多余的重复命令、再装一个每 5 分钟自动检查的小守卫。不想懂原理也能用。

## 常见问题

**Q: 报错说找不到 node？**
先装好 Node（推荐 24.18.0），再重跑脚本。

**Q: 自动防护的日志在哪？**
`/tmp/ccswitch-watchdog.out.log`

**Q: 怎么卸载自动防护？**
运行上面的 `--uninstall-watchdog` 命令即可。

## License

MIT
