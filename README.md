# Keep Awake

一个 macOS 菜单栏小工具，用来控制屏幕和电脑的防睡眠状态，并在状态栏图标里显示 Logitech 鼠标电量。

## 功能

- `保持屏幕亮起`：开启后屏幕不会自动熄灭，同时会自动开启防止电脑自动睡眠。
- `防止电脑自动睡眠（屏幕可熄灭）`：电脑保持唤醒，但允许屏幕按系统设置熄灭。
- `开机自动启动`：从当前 `Keep Awake.app` 写入用户级 LaunchAgent，下次登录后自动启动。
- 状态栏图标使用显示器样式，图标内显示 Logitech 电量百分比。
- Logitech 电量在启动时读取一次，之后每 24 小时刷新一次；也可以在菜单里手动点击 `刷新电池电量`。

## 构建

```sh
./scripts/build_app.sh
```

脚本会构建 release 版本，并在项目根目录生成本地可运行的 `Keep Awake.app`。构建产物不会提交到 Git。

## Logitech 电量读取

电量读取脚本位于 `Resources/check_logi_battery.py`，打包时会复制到 app bundle 的 `Contents/Resources`。运行环境需要本机可用的 `python3`，并安装 `hid` Python 包；应用会从 Python Framework、`PATH` 和常见 Homebrew 路径自动查找，也可以通过 `LOGI_BATTERY_PYTHON` 指定 Python 路径。
