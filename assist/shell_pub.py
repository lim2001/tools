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

import rclpy
from rclpy.node import Node
from std_msgs.msg import String
import multiprocessing
import os
import time
from threading import Thread

class ROS2Publisher(Node):
    def __init__(self):
        super().__init__('background_publisher')
        self.publisher_ = self.create_publisher(String, 'shell', 10)
        print("[ROS2Publisher] Node initialized and publisher created.")

    def publish_message(self, msg):
        ros_msg = String()
        ros_msg.data = msg
        self.publisher_.publish(ros_msg)

        if self.publisher_.get_subscription_count() > 0:
            print(f"[ROS2Publisher] Published: {msg}")
        else:
            print(f"[ROS2Publisher] No subscribers, message '{msg}' not received.")

def publisher_process(message_queue, event):
    print(f"[Publisher Process {os.getpid()}] Initializing ROS2...")
    rclpy.init()
    node = ROS2Publisher()
    executor = rclpy.executors.SingleThreadedExecutor()
    executor.add_node(node)

    def run_executor():
        while rclpy.ok():
            try:
                msg = message_queue.get_nowait()  # 非阻塞获取消息
                print(f"[Publisher Process] Received message: {msg}")
                node.publish_message(msg)  # 发布消息
                event.clear()  # 清除事件，等待下一次触发
                break  # 发布完消息后退出
            except:
                pass
            executor.spin_once(timeout_sec=0.1)  # 非阻塞地等待事件

    # 启动一个线程运行发布器
    executor_thread = Thread(target=run_executor)
    executor_thread.daemon = True
    executor_thread.start()

    last_print_time = time.time()
    while True:
        # 每隔2秒打印一次活动信息
        if time.time() - last_print_time >= 2:
            print("[Publisher Process] active ...")
            last_print_time = time.time()

        # 检查后台线程是否结束
        if not executor_thread.is_alive():
            break

    # 这里延迟关闭 ROS2 上下文，避免立即关闭
    print("[Publisher Process] Shutting down ROS2...")
    time.sleep(0.1)  # 延迟一些时间确保发布完消息
    node.destroy_node()
    rclpy.shutdown()

# 使用 multiprocessing 创建发布进程
message_queue = multiprocessing.Queue()
publisher_process_instance = None
event = multiprocessing.Event()  # 事件对象，用于触发消息发布

def start_publisher():
    """ 确保发布进程一直在运行 """
    global publisher_process_instance
    if publisher_process_instance is None or not publisher_process_instance.is_alive():
        print("[start_publisher] Starting new publisher process...")
        publisher_process_instance = multiprocessing.Process(target=publisher_process, args=(message_queue, event))
        publisher_process_instance.daemon = True  # 守护进程，主程序退出时自动结束
        publisher_process_instance.start()
    else:
        print("[start_publisher] Publisher process is already running.")

def publish_message(arg1):
    """ 启动发布进程并发送消息 """
    print(f"[publish_message] Publishing: {arg1}")
    start_publisher()  # 确保进程在运行
    message_queue.put(arg1)
    event.set()  # 触发发布事件
    print(f"[publish_message] Message '{arg1}' added to queue.")

if __name__ == '__main__':
    # 发布完消息后立即退出
    publish_message("ljlejl")
    print("[pythonb] Message sent.")
