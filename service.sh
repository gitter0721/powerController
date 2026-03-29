#!/system/bin/sh

# ==============================
# 路径与变量定义
# ==============================
MODDIR=${0%/*}
BYPASS_NODE="/sys/devices/virtual/oplus_chg/battery/mmi_charging_enable"
CAPACITY_NODE="/sys/class/power_supply/battery/capacity"
USB_ONLINE_NODE="/sys/class/power_supply/usb/online"
MAX_SIZE=1048576
LOG_FILE="$MODDIR/bypass.log"

UPPER_LIMIT=95  # 上限：大于等于此值时，开启旁路（停充）
LOWER_LIMIT=91  # 下限：小于等于此值时，关闭旁路（复充）

BASE_DESC="一加pad2pro专用，可强制开启旁路充电。可以自定义值，刷入后在 /data/adb/modules/oplusPowerController/service.sh 内可修改你想要的值。默认大于等于91%电量进入旁路充电，低于等于78%电量恢复正常充电，处于中间值时等待10秒后重新插入充电器仍可充电。⚠️警告:关闭或卸载模块后需要等待10秒钟生效，未等待进行关机可能导致的问题后果自负⚠️"

# 用于记录上一次的状态，防止日志无限刷屏以及频繁读写 module.prop 磨损闪存
LAST_STATE=""

# ==============================
# 辅助函数定义
# ==============================
log() {
    # 格式化时间
    CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$CURRENT_TIME] $1" >> "$LOG_FILE"
}

# 动态修改 module.prop 里的描述文字
update_prop_desc() {
    local status_text="$1"
    # 使用 sed 命令替换 description 
    sed -i "s|^description=.*|description=【状态：$status_text】 $BASE_DESC|g" "$MODDIR/module.prop"
}

# ==============================
# 初始化与开机等待
# ==============================
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2
done

echo "=== OPPO/OnePlus 旁路充电控制模块已启动 ===" >> "$LOG_FILE"
log "系统启动完成，检查节点..."

# ==============================
# 节点可用性检测
# ==============================
if [ ! -f "$BYPASS_NODE" ] || [ ! -f "$CAPACITY_NODE" ] || [ ! -f "$USB_ONLINE_NODE" ]; then
    log "error错误：设备缺少必需的节点！模块将停止运行。"
    # 修改描述为错误状态，并直接退出脚本
    update_prop_desc "❌ 运行失败 (未找到节点)"
    exit 1
fi

echo 1 > "$BYPASS_NODE"
log "已执行安全兜底：默认恢复充电能力"
update_prop_desc "🥳初始化完成"

# ==============================
# 核心守护进程
# ==============================
while true; do
    # 如果关闭或者卸载模块，恢复正常充电
    if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
        if [ "$LAST_STATE" != "DISABLED" ]; then
            echo 1 > "$BYPASS_NODE"
            log "模块被停用或处于卸载状态，已恢复正常满充能力。"
            update_prop_desc "🔴 模块已停用"
            LAST_STATE="DISABLED"
        fi
    else
        # 读取当前状态
        CAPACITY=$(cat "$CAPACITY_NODE")
        USB_ONLINE=$(cat "$USB_ONLINE_NODE")
        
        # 优先判断充电器是否被拔掉
        if [ "$USB_ONLINE" -eq 0 ]; then
            if [ "$LAST_STATE" != "UNPLUGGED" ]; then
                echo 1 > "$BYPASS_NODE"
                log "充电器已拔出 (电量 $CAPACITY%)，重置节点为可充电状态。"
                update_prop_desc "🔋 未接电源"
                LAST_STATE="UNPLUGGED"
            fi
        else
            # 插着充电器，进入电量区间逻辑
            if [ "$CAPACITY" -ge "$UPPER_LIMIT" ]; then
                if [ "$LAST_STATE" != "BYPASS_ON" ]; then
                    echo 0 > "$BYPASS_NODE"
                    log "电量达到 $CAPACITY% (>= $UPPER_LIMIT%)，触发旁路供电"
                    update_prop_desc "⚡ 旁路供电中"
                    LAST_STATE="BYPASS_ON"
                fi
            elif [ "$CAPACITY" -le "$LOWER_LIMIT" ]; then
                if [ "$LAST_STATE" != "CHARGING" ]; then
                    echo 1 > "$BYPASS_NODE"
                    log "电量降至 $CAPACITY% (<= $LOWER_LIMIT%)，恢复快速充电。"
                    update_prop_desc "🟢 正常充电中"
                    LAST_STATE="CHARGING"
                fi
            else
                # 电量处于中间防抖状态
                if [ "$LAST_STATE" != "WAITING" ] && [ "$LAST_STATE" != "CHARGING" ] && [ "$LAST_STATE" != "BYPASS_ON" ]; then
                    log "电量为 $CAPACITY%，处于设定区间内，维持上一次状态不变。"
                    update_prop_desc "⏳ 旁路充电中,等待阈值触发"
                    LAST_STATE="WAITING"
                fi
            fi
        fi
    fi
    
    # 检查文件是否存在与自动清理日志
    if [ -f "$LOG_FILE" ]; then
        FILE_SIZE=$(stat -c%s "$LOG_FILE")
        if [ "$FILE_SIZE" -gt "$MAX_SIZE" ]; then
            : > "$LOG_FILE"
            log "日志超过1MB，已执行自动清空。" > "$LOG_FILE"
        fi
    fi
    
    # 间隔 10 秒检测一次
    sleep 10
done