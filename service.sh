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
CONFIG_FILE="$MODDIR/config.txt"

BASE_DESC="一加pad2pro可用(其他o系设备可以刷入测试)，可强制开启旁路充电。自定义值->刷入后在 /data/adb/modules/oplusPowerController/config.txt 内可修改你想要的值,修改后立即生效。默认大于等于91%电量进入旁路充电，低于等于78%电量恢复正常充电"

LAST_STATE=""

# ==============================
# 辅助函数定义
# ==============================
log() {
    CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$CURRENT_TIME] $1" >> "$LOG_FILE"
}

update_prop_desc() {
    local status_text="$1"
    sed -i "s|^description=.*|description=【当前状态：$status_text】 $BASE_DESC|g" "$MODDIR/module.prop"
}

# ==============================
# 初始化与开机等待
# ==============================
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2
done

echo "=== OPPO/OnePlus 旁路充电控制模块已启动 ===" >> "$LOG_FILE"
log "系统启动完成，检查节点..."

if [ ! -f "$BYPASS_NODE" ] || [ ! -f "$CAPACITY_NODE" ] || [ ! -f "$USB_ONLINE_NODE" ]; then
    log "error错误：设备缺少必需的电源节点！模块将停止运行。"
    update_prop_desc "❌ 该设备无法使用该模块！"
    exit 1
fi


echo 1 > "$BYPASS_NODE"
log "已执行安全兜底：默认恢复充电能力"
update_prop_desc "🥳 初始化完成"

# ==============================
# 核心守护进程
# ==============================
while true; do

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "UPPER_LIMIT=91" > "$CONFIG_FILE"
        echo "LOWER_LIMIT=78" >> "$CONFIG_FILE"
        log "未找到配置文件，已自动生成 config.txt 并写入默认值 91/78。"
    fi

    CURRENT_UPPER=$(grep -m 1 "^UPPER_LIMIT=" "$CONFIG_FILE" | cut -d= -f2 | awk '{print $1}')
    CURRENT_LOWER=$(grep -m 1 "^LOWER_LIMIT=" "$CONFIG_FILE" | cut -d= -f2 | awk '{print $1}')
    
    # 校验
    if echo "$CURRENT_UPPER" | grep -qE '^[0-9]+$' && [ "$CURRENT_UPPER" -ge 0 ] && [ "$CURRENT_UPPER" -le 100 ]; then
        ACTIVE_UPPER=$CURRENT_UPPER
    else
        ACTIVE_UPPER=91
    fi

    if echo "$CURRENT_LOWER" | grep -qE '^[0-9]+$' && [ "$CURRENT_LOWER" -ge 0 ] && [ "$CURRENT_LOWER" -le 100 ]; then
        ACTIVE_LOWER=$CURRENT_LOWER
    else
        ACTIVE_LOWER=78
    fi

    # 上限必须大于下限
    if [ "$ACTIVE_UPPER" -le "$ACTIVE_LOWER" ]; then
        ACTIVE_UPPER=91
        ACTIVE_LOWER=78
    fi

    if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
        if [ "$LAST_STATE" != "DISABLED" ]; then
            echo 1 > "$BYPASS_NODE"
            log "模块被停用或处于卸载状态，已恢复正常满充能力。"
            update_prop_desc "🔴 模块已停用"
            LAST_STATE="DISABLED"
        fi
    else
        CAPACITY=$(cat "$CAPACITY_NODE")
        USB_ONLINE=$(cat "$USB_ONLINE_NODE")
        
        if [ "$USB_ONLINE" -eq 0 ]; then
            if [ "$LAST_STATE" != "UNPLUGGED" ]; then
                echo 1 > "$BYPASS_NODE"
                log "充电器已拔出 (电量 $CAPACITY%)，重置节点为可充电状态。"
                update_prop_desc "💤 未接电源"
                LAST_STATE="UNPLUGGED"
            fi
        else
            if [ "$CAPACITY" -ge "$ACTIVE_UPPER" ]; then
                if [ "$LAST_STATE" != "BYPASS_ON" ]; then
                    echo 0 > "$BYPASS_NODE"
                    log "电量达到 $CAPACITY% (>= 设定上限 $ACTIVE_UPPER%)，触发旁路供电"
                    update_prop_desc "⚡ 旁路供电中"
                    LAST_STATE="BYPASS_ON"
                fi
            elif [ "$CAPACITY" -le "$ACTIVE_LOWER" ]; then
                if [ "$LAST_STATE" != "CHARGING" ]; then
                    echo 1 > "$BYPASS_NODE"
                    log "电量降至 $CAPACITY% (<= 设定下限 $ACTIVE_LOWER%)，恢复快速充电。"
                    update_prop_desc "🟢 正常充电中"
                    LAST_STATE="CHARGING"
                fi
            else
                if [ "$LAST_STATE" = "BYPASS_ON" ] || [ "$LAST_STATE" = "WAITING_DOWN" ]; then
                    if [ "$LAST_STATE" != "WAITING_DOWN" ]; then
                        log "电量为 $CAPACITY%，位于区间内，维持旁路状态，等待降至 $ACTIVE_LOWER%。"
                        update_prop_desc "⚡ 旁路中 (等待降至 $ACTIVE_LOWER%)"
                        LAST_STATE="WAITING_DOWN"
                    fi
                else
                    if [ "$LAST_STATE" != "WAITING_UP" ]; then
                        log "电量为 $CAPACITY%，位于区间内，维持充电状态，等待充至 $ACTIVE_UPPER%。"
                        update_prop_desc "🟢 充电中 (等待充至 $ACTIVE_UPPER%)"
                        LAST_STATE="WAITING_UP"
                    fi
                fi
            fi
        fi
    fi
    
    if [ -f "$LOG_FILE" ]; then
        FILE_SIZE=$(stat -c%s "$LOG_FILE")
        if [ "$FILE_SIZE" -gt "$MAX_SIZE" ]; then
            : > "$LOG_FILE"
            log "日志超过1MB，已执行自动清空。" > "$LOG_FILE"
        fi
    fi
    
    sleep 10
done