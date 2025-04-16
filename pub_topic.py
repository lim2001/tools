"""
publish topic /shell with a string message and test timespend
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

import rclpy
import time
from rclpy.node import Node
from std_msgs.msg import String
from datetime import datetime

description = "This is  test2.py, a tool for demo sample -- publisher a string message and test timespend."
def publish_once():


    now = datetime.now()
    formatted_now = now.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    print("11111 ",formatted_now)

    # 初始化rclpy
    rclpy.init()

    now = datetime.now()
    formatted_now = now.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    print("22222 ",formatted_now)

    # 创建一个节点
    node = Node('shell_publisher_once')

    now = datetime.now()
    formatted_now = now.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    print("33333 ",formatted_now)

    start_time = time.time()
    msgtime_str = str(start_time)

    # 创建一个发布者，发布到'/shell'话题，消息类型为std_msgs/msg/String
    publisher = node.create_publisher(String, 'shell', 10)

    now = datetime.now()
    formatted_now = now.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    print("44444 ",formatted_now)

    # 创建消息
    message = String()
    message.data = msgtime_str

    # 发布消息
    publisher.publish(message)

    now = datetime.now()
    formatted_now = now.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    print("55555 ",formatted_now)



    # 销毁节点
    node.destroy_node()
    rclpy.shutdown()

if __name__ == '__main__':
    now = datetime.now()
    formatted_now = now.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    print("0000 ",formatted_now)
    publish_once()