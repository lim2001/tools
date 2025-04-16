"""
open/close camera test (open =launch, close = ctrl+c) and auto test depth is normal
"""

# Copyright (c) 2025 Orbbec 3D Technology, Inc
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


import subprocess
import time
import os
import signal

# 设置循环次数，如果需要无限循环，可以设置为None
loop_count = 10000

# 初始化开关次数
toggle_count = 0

# 错误标志文件的路径
error_flag_file = '/home/ytj/error_flag'

# 子进程列表
processes = []

# 定义信号处理函数
def signal_handler(sig, frame):
    print("\nReceived interrupt signal (Ctrl+C). Stopping all launch files...")
    for process in processes:
        process.terminate()
        process.wait()
    print("All launch files have been stopped.")
    exit(0)

# 注册信号处理函数
signal.signal(signal.SIGINT, signal_handler)

# 循环控制
while loop_count is None or toggle_count < loop_count:
    # 启动launch文件
    try:
        process = subprocess.Popen(['ros2', 'launch', 'orbbec_camera', 'multi_camera_synced.launch.py'])
        print(f"Launch camera re-started: total cycle : {toggle_count}")
        processes.append(process)  # 将进程添加到列表中
    except Exception as e:
        print(f"Failed to start launch file: {e}")
        break  # 如果启动失败，则退出循环

    # 运行10秒
    time.sleep(13)

    # 检查错误标志文件是否存在
    if os.path.exists(error_flag_file):
        print("----------------------------------------------------------------------")
        print("---------- Error, /home/ytj/error_flag file exists. Stopping the pressure test.")
        print("----------------------------------------------------------------------")

        # 如果文件存在，每隔一秒打印一次错误提示
        while os.path.exists(error_flag_file):
            print("----------------------------------------------------------------------")
            print("---------- Error, /home/ytj/error_flag file exists. the pressure test had been stop")
            print("----------------------------------------------------------------------")
            time.sleep(1)  # 等待一秒

        # 文件不存在后，退出循环
        break


    # 关闭launch文件
    process.terminate()
    process.wait()
    print(f"Launch camera test: total cycle :{toggle_count}")
    print(f"close camera")

    # 延时10秒
    time.sleep(10)

    # 更新开关次数
    toggle_count += 1

    # 如果有循环次数限制，检查是否达到循环次数
    if loop_count is not None and toggle_count >= loop_count:
        break

    # 清理进程列表，只保留当前循环的进程
    processes = [process]

print("Pressure test completed.")