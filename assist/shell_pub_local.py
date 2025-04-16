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
from rclpy.qos import QoSProfile, QoSHistoryPolicy, QoSReliabilityPolicy, QoSDurabilityPolicy
import os
def publish_message_local(msg, topic_name='/shell'):

    rclpy.init()

    node = Node('shell_publisher')

    qos_profile = QoSProfile(
        depth=1,
        reliability=QoSReliabilityPolicy.BEST_EFFORT,
        history=QoSHistoryPolicy.KEEP_LAST
    )

    publisher = node.create_publisher(String, topic_name, 1)


    if publisher.get_subscription_count() > 0:

        message = String()
        message.data = msg

        publisher.publish(message)
        print(f'publish /shell "{msg}"')
    else:
        print('publish /shell subscribers not found')

    node.destroy_node()
    rclpy.shutdown()


if __name__ == '__main__':
    publish_message_local("Hello, ROS 2 Shell!")