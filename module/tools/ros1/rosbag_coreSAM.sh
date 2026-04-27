#!/usr/bin/env bash

# 定義數據對 (注意：數量必須一致)
Y_LIST=(0.0 0.1 0.2 0.3)
F2S_LIST=(0.350 0.246 0.149 0.049)

Z_LIST=(2.0 2.02 2.04 2.06 2.08 2.10 2.12 2.14 2.16)
F2G_LIST=(1.957 1.974 1.996 2.014 2.033 2.053 2.076 2.095 2.119)

if [[ ! -d bag ]]; then
    mkdir bag
fi

# 第一層：LED 切換
for LED_STATUS in false true; do
    # 轉換 LED 狀態為 ROS 格式 (0 或 1)
    LED_VAL=0
    [[ "$LED_STATUS" == "true" ]] && LED_VAL=1

    # 第二層：遍歷 Y 軸 (使用索引 i)
    for i in "${!Y_LIST[@]}"; do
        cmd_y=${Y_LIST[$i]}
        curr_f2s=${F2S_LIST[$i]}

        # 第三層：遍歷 Z 軸 (使用索引 j)
        for j in "${!Z_LIST[@]}"; do
            cmd_z=${Z_LIST[$j]}
            curr_f2g=${F2G_LIST[$j]}

            echo "------------------------------------------------"
            echo "正在執行: LED=$LED_STATUS, Y=$cmd_y, Z=$cmd_z"

            rostopic pub -1 /fork_y_command std_msgs/Float64 "data: $cmd_y" &&
            rostopic pub -1 /fork_z_command std_msgs/Float64 "data: $cmd_z" &&
            rostopic pub -1 /indicators/fill_light_on std_msgs/UInt8 "data: $LED_VAL"

            sleep 5
            echo "取得目前牙叉位置..."
            read -r curr_y curr_z < <(rostopic echo -n 1 /fork_positions_m | awk '/data:/ {gsub(/[\[\],]/, "", $0); print $(NF-1), $NF}')

            # 2. 開始錄製 rosbag
            # 檔名解析：${LED_STATUS:0:1} 會取 t 或 f
            BAG_NAME="$(hostname)_camera_wood_5M_${cmd_y}-${cmd_z}-${LED_STATUS:0:1}_${curr_f2s}-${curr_f2g}_${curr_y}-${curr_z}_$(date +%Y%m%d-%H%M%S).bag"

            echo "正在錄製: $BAG_NAME"
            # timeout 30s rosbag record -e "/camera.*" -O "bag/$BAG_NAME"
            rosbag record \
                -O "bag/$BAG_NAME" \
                --duration="5s" \
                /camera_image_raw /camera_info

            echo "錄製完成。"
        done
    done
done


rostopic pub -1 /fork_y_command std_msgs/Float64 "data: 0.0" &&
rostopic pub -1 /fork_z_command std_msgs/Float64 "data: 2.0" &&
rostopic pub -1 /indicators/fill_light_on std_msgs/UInt8 "data: 0"
