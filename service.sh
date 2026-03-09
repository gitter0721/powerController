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

UPPER_LIMIT=91  # 上限：大于等于此值时，开启旁路（停充）
LOWER_LIMIT=78  # 下限：小于等于此值时，关闭旁路（复充）

# 用于记录上一次的状态，防止日志无限刷屏
LAST_STATE=""

# ==============================
# 日志函数定义
# ==============================
log() {
    # 格式化时间
    CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$CURRENT_TIME] $1" >> "$LOG_FILE"
}

# ==============================
# 初始化与开机等待
# ==============================
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2
done


echo "=== OPPO/OnePlus 旁路充电控制模块已启动 ===" >> "$LOG_FILE"
log "系统启动完成，初始化节点..."
echo 1 > "$BYPASS_NODE"
log "已执行安全兜底：默认恢复充电能力"

# ==============================
# 核心守护进程
# ==============================
while true; do
    # 如果关闭或者卸载模块，恢复正常充电
    if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
        if [ "$LAST_STATE" != "DISABLED" ]; then
            echo 1 > "$BYPASS_NODE"
            log "模块被停用或处于卸载状态，已恢复正常满充能力。"
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
                LAST_STATE="UNPLUGGED"
            fi
        else
            # 插着充电器，进入电量区间逻辑
            if [ "$CAPACITY" -ge "$UPPER_LIMIT" ]; then
                if [ "$LAST_STATE" != "BYPASS_ON" ]; then
                    echo 0 > "$BYPASS_NODE"
                    log "电量达到 $CAPACITY% (>= $UPPER_LIMIT%)，触发旁路供电"
                    LAST_STATE="BYPASS_ON"
                fi
            elif [ "$CAPACITY" -le "$LOWER_LIMIT" ]; then
                if [ "$LAST_STATE" != "CHARGING" ]; then
                    echo 1 > "$BYPASS_NODE"
                    log "电量降至 $CAPACITY% (<= $LOWER_LIMIT%)，恢复快速充电。"
                    LAST_STATE="CHARGING"
                fi
            else
                # 电量处于中间防抖状态
                if [ "$LAST_STATE" != "WAITING" ] && [ "$LAST_STATE" != "CHARGING" ] && [ "$LAST_STATE" != "BYPASS_ON" ]; then
                    # 只有从断电或开机直接进入这个区间时才打印一次
                    log "电量为 $CAPACITY%，处于设定区间内，维持上一次状态不变。"
                    LAST_STATE="WAITING"
                fi
            fi
        fi
    fi
    
    # 检查文件是否存在
if [ -f "$LOG_FILE" ]; then
    # 获取文件当前大小 
    FILE_SIZE=$(stat -c%s "$LOG_FILE")

    # 判断是否超过设定大小
    if [ "$FILE_SIZE" -gt "$MAX_SIZE" ]; then
        # 清空文件内容，但保留文件
        : > "$LOG_FILE"
        
        # 记录一次清理日志的操作
        log "日志超过1MB，已执行自动清空。" > "$LOG_FILE"
    fi
fi
    
    # 间隔 10 秒检测一次
    sleep 10
done