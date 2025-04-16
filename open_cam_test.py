"""
open/close camera test (open =launch, close = ctrl+c) and auto verify depth image
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
import threading
import time
import sys
import psutil

###################################################
#配置默认参数:
#执行命令
#cmd_1 = "ros2 launch orbbec_camera multi_camera_synced.launch.py"
cmd_1 = "ros2 launch orbbec_camera orbbec_camera.launch.py"




total_count = 10000   #执行总次数. 达到该次数后,压测停止
cmd_run_delay_sec = 10   #执行cmd_1之后的延时时间(秒) . 经过此时间后,会执行退出命令
cmd_off_delay_sec = 5   #执行退出cmd之后的延时时间(秒)



terminate_test_when_fail = False #True  #遇到异常停止压测
fail_count = 0
test_ok = 1
###################################################










###################################################
error_flag_file = '/home/ytj/error_flag'

current_test_count = 0  # 初始化开关次数

processes = []

def print_test_status():
    print("----------------------------------------------------------------------")
    print(f"cmd_1 = {cmd_1}")

    print(f"cmd_run_delay_sec = {cmd_run_delay_sec}s")
    print(f"cmd_off_delay_sec = {cmd_off_delay_sec}s")
    print(f"total_count = {total_count}")
    print(f"result/report :  fail_count= {fail_count}  /  current_test_count= {current_test_count}" )
    if os.path.exists(error_flag_file):
        print(f"fail  /home/ytj/error_flag file exists.")
    print("----------------------------------------------------------------------")

def signal_handler(sig, frame):
    print("\nReceived interrupt signal (Ctrl+C). Stopping all launch files...")
    for process in processes:
        process.terminate()
        process.wait()
    print("All launch files have been stopped.")
    print_test_status()
    exit(0)

def print_time_non_blocking():

    def _print_time():
        while True:
            current_time = time.strftime("%H:%M:%S")
            print(current_time)
            time.sleep(1)
    thread = threading.Thread(target=_print_time)
    thread.daemon = True  # 设置为守护线程，主线程结束时自动退出
    thread.start()
    return thread

def terminate_process_tree(pid):
    try:
        parent = psutil.Process(pid)
        for child in parent.children(recursive=True):
            child.terminate()
        parent.terminate()
    except psutil.NoSuchProcess:
        print(f"Process with PID {pid} does not exist.")



# 注册信号处理函数
signal.signal(signal.SIGINT, signal_handler)

print("\n\n")
print("----------------------------------------------------------------------")
print("-    open cam test tool      -")
print("----------------------------------------------------------------------")
if os.path.exists(error_flag_file):
    os.remove(error_flag_file)  # 删除文件
    print(f"last test {error_flag_file} is exist , clean last result")

print_time_non_blocking()


# 循环控制
while total_count is None or current_test_count < total_count:
    # 启动launch文件
    try:
        if os.path.exists(error_flag_file):
            os.remove(error_flag_file)# 删除文件
        test_ok = 1
        print("\n\n")
        print(f"test start, open camera:")
        print_test_status()
        # process = subprocess.Popen(cmd_1, shell=True)
        # process = subprocess.Popen(cmd_1, shell=True)
        process = subprocess.Popen(['ros2', 'launch', 'orbbec_camera', 'orbbec_camera.launch.py'])
        processes.append(process)  # 将进程添加到列表中
    except Exception as e:
        print(f"Failed to start launch file: {e} \n\n")
        break  # 如果启动失败，则退出循环
    print(f"delay cmd_run_delay_sec: {cmd_run_delay_sec}s")

    time.sleep(5)

    print(f"start monitor.py")
    script_dir = os.path.dirname(os.path.abspath(__file__))  # 获取当前脚本路径
    sub_script = os.path.join(script_dir, 'monitor.py')  #monitor.py  test1.py

    process_monitor = subprocess.Popen(
        [sys.executable, sub_script],  # 使用当前 Python 解释器来运行 sub.py
        stdout=sys.stdout,  # 重定向 stdout 到主脚本的终端
        stderr=sys.stderr   # 重定向 stderr 到主脚本的终端
    )

    time.sleep(cmd_run_delay_sec - 5)

    if os.path.exists(error_flag_file):
        print("test fail")
        test_ok = 0



    process_monitor.terminate()
    process_monitor.wait()
    print(f"exit monitor.py")
    time.sleep(1)
    process.send_signal(signal.SIGINT)
    process.wait()

    current_test_count += 1
    if test_ok == 0:
        fail_count += 1

    print(f"test finished, close camera:")
    print_test_status()
    print("\n\n")

    if test_ok == 0:
        if terminate_test_when_fail:
            print("terminate_test_when_fail \n\n")
            break

    if total_count is not None and current_test_count >= total_count:
        break

    time.sleep(cmd_off_delay_sec)
    # 清理进程列表，只保留当前循环的进程
    processes = [process]


print("----------------------------------------------------------------------")
print("-    open cam test tool   completed   -")
print("----------------------------------------------------------------------")