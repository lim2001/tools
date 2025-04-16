"""
monitor hz,timestamp,drop frame of topics: eg. monitor_auto.py -- auto search topic, monitor_auto.py config -- config manual
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
import threading
import struct
import argparse
import datetime
import sys
import subprocess
import re
import cv2
import os
import numpy as np
import datetime
import atexit
import struct
import time
import traceback
import builtins

from rclpy.node import Node
from rclpy.executors import MultiThreadedExecutor
from sensor_msgs.msg import Image, PointCloud2
from cv_bridge import CvBridge, CvBridgeError
from rclpy.node import Node
from rclpy.executors import MultiThreadedExecutor
from tf2_ros import Buffer, TransformListener
from geometry_msgs.msg import TransformStamped
from rosidl_runtime_py.utilities import get_message
from sensor_msgs.msg import Image, PointCloud2
from functools import partial

#######################################################
#

OUTPUT_FILE_PATH = "~/_data/save_image"


topics_monitor = [
    ("/camera/depth/image_raw", "sensor_msgs/msg/Image"),
    ("/camera/color/image_raw", "sensor_msgs/msg/Image"),
    #("/camera/depth/points", "sensor_msgs/msg/PointCloud2"),
    # add config topic
]

# topics_monitor = [
#     ("/cam0/color/image_raw", "sensor_msgs/msg/Image"),
#     ("/cam1/color/image_raw", "sensor_msgs/msg/Image"),
#     ("/cam2/color/image_raw", "sensor_msgs/msg/Image"),
#     ("/cam3/color/image_raw", "sensor_msgs/msg/Image"),
#     ("/cam4/color/image_raw", "sensor_msgs/msg/Image"),
#     ("/cam0/depth/image_raw", "sensor_msgs/msg/Image"),
#     ("/cam1/depth/image_raw", "sensor_msgs/msg/Image"),
#     ("/cam2/depth/image_raw", "sensor_msgs/msg/Image"),
#     ("/cam3/depth/image_raw", "sensor_msgs/msg/Image"),
#     ("/cam4/depth/image_raw", "sensor_msgs/msg/Image"),
#     ("/cam0/left_ir/image_raw", "sensor_msgs/msg/Image"),
#     ("/cam1/left_ir/image_raw", "sensor_msgs/msg/Image"),
#     ("/cam2/left_ir/image_raw", "sensor_msgs/msg/Image"),
#     ("/cam3/left_ir/image_raw", "sensor_msgs/msg/Image"),
#     ("/cam4/left_ir/image_raw", "sensor_msgs/msg/Image"),
#     # ("/cam0/depth/points", "sensor_msgs/msg/PointCloud2"),
#     # ("/cam1/depth/points", "sensor_msgs/msg/PointCloud2"),
#     # ("/cam2/depth/points", "sensor_msgs/msg/PointCloud2"),
#     # ("/cam3/depth/points", "sensor_msgs/msg/PointCloud2"),
#     # ("/cam4/depth/points", "sensor_msgs/msg/PointCloud2"),
#     ("/cam0_pcl", "sensor_msgs/msg/PointCloud2"),
#     ("/cam1_pcl", "sensor_msgs/msg/PointCloud2"),
#     ("/cam2_pcl", "sensor_msgs/msg/PointCloud2"),
#     ("/cam3_pcl", "sensor_msgs/msg/PointCloud2"),
#     ("/cam4_pcl", "sensor_msgs/msg/PointCloud2"),
# ]
#######################################################

topics_test_result = {
    topic_name: {
        "topic_name": topic_name,
        "topic_type": topic_type_str,
        "has_publisher": 0,
        "average_interval_ms": 0,
        "data_content": [0] * 16,
        "status": "checking",
        "last_time": 0,
        "timestamp": 0,
        "last_timestamp": 0,
        "diff_timestamp": 0,
        "curr_diff_timestamp": 0,
        "frame_id_cnt": 0,
        "frame_drop_count": 0,
        "height": 0,
        "width": 0
    }
    for topic_name, topic_type_str in topics_monitor
}

debug_enable = 1  #debug switch

topics_to_subscribe = []
total_image = 0


#######################################################
def print_debug(*args, **kwargs):
    global debug_enable
    debug_enable = int(debug_enable)
    if debug_enable != 1:
        return
    timestamp = datetime.datetime.now().strftime("[%m %H:%M:%S.%f")[:-3]+ "]"
    builtins.print(timestamp, *args, **kwargs)

def print(*args, **kwargs):
    timestamp = datetime.datetime.now().strftime("[%m %H:%M:%S.%f")[:-3]+ "]"
    builtins.print(timestamp, *args, **kwargs)

def print_topics(topics, title="Topics:"):
    print(f"{title}")
    for topic_name, topic_type_str in topics:
        #print(f"Topic: {topic_name}, Type: {topic_class.__name__}")
        print(f"(\"{topic_name}\", \"{topic_type_str}\"), ")
    print(f"total: {len(topics)}")

def safe_exit(exit_code=0, message=""):
    if message != "":
        print(f"{message}")
    try:
        if rclpy.ok():
            rclpy.shutdown()
    except Exception as e:
        print(f"exit warning: {e}")
        traceback.print_exc()
    finally:
        sys.exit(exit_code)


class TopicSubscriber(Node):
    def __init__(self, topics_to_subscribe):
        super().__init__("topic_subscriber")
        self.logger = self.get_logger()
        self.bridge = CvBridge()  # Initialize CvBridge
        self.save_path = self.create_save_directory()
        self.saved_topics = set()  # Track saved topics

        self.subscribe_topics(topics_to_subscribe)
        self.timeout_timer = self.create_timer(1, self.check_timeout)
        self.start_time = self.get_clock().now()

    def subscribe_topics(self, topics_to_subscribe):
        for topic_name, topic_type_str in topics_to_subscribe:
            # 动态导入消息类型
            topic_class = get_message(topic_type_str)
            self.create_subscription(
                topic_class ,
                topic_name,
                #lambda msg, tn=topic_name, tt=topic_type.__name__: callback(msg, tn, tt),
				partial(self.callback_default, topic_name=topic_name, topic_type_str=topic_type_str),
                10  # QoS
            )
            print(f"Subscribed topic: {topic_name:<30} {topic_type_str}")
        print(f"--------------------------------------------------------------")

    def create_save_directory(self):
        out_path = os.path.expanduser(OUTPUT_FILE_PATH)
        os.makedirs(out_path, exist_ok=True)
        print(f"Output path: {out_path}")

        # Create the timestamped save directory within the 'out' folder
        timestamp = datetime.datetime.now().strftime("%d%H_%M%S")
        save_path = os.path.join(out_path, f'image_{timestamp}')
        os.makedirs(save_path, exist_ok=True)
        return save_path

    def callback_default(self, msg, topic_name, topic_type_str):
        global topics_to_subscribe
        global total_image
        if topic_name not in self.saved_topics:
            self.saved_topics.add(topic_name)
            if topic_type_str in ["sensor_msgs/msg/Image"]:
                self.save_image(msg, topic_name)
            elif topic_type_str == "sensor_msgs/msg/PointCloud2":
                self.save_point_cloud(msg, topic_name)
            #print(f"Saved image : {len(self.saved_topics)} /{len(topics_to_subscribe)}/")
            else:
                print(f"skip, not support: {topic_type_str} , ")

        if len(self.saved_topics) == len(topics_to_subscribe):
            print(f"saved image total {total_image}, output path: {self.save_path}/")

            safe_exit(0,"saved image success")

    def save_image(self, msg, topic_name):
        frame_id = msg.header.frame_id
        topic_base_name = topic_name.replace("/", "_")
        image_file = os.path.join(self.save_path, f'{topic_base_name}_{frame_id}.jpg')
        global total_image

        #print(f"Saved image : {len(self.saved_topics)} /{len(topics_to_subscribe)}/")
        try:
            if msg.encoding in ['16UC1', '32FC1']:
                # Convert and save depth image
                cv_image = self.bridge.imgmsg_to_cv2(msg, desired_encoding="passthrough")
                image_file = image_file.replace('.jpg', '.png')  # Use PNG for depth images
                cv2.imwrite(image_file, cv_image)
                print(f'Saved {len(self.saved_topics)}/{len(topics_to_subscribe)}: {topic_name:<26} to {image_file}')
                # Save raw depth data
                raw_file = os.path.join(self.save_path, f'{topic_base_name}_{frame_id}.raw')
                np_array = np.array(cv_image, dtype=np.uint16 if msg.encoding == '16UC1' else np.float32)
                np_array.tofile(raw_file)
                print(f'Saved {len(self.saved_topics)}/{len(topics_to_subscribe)}: {topic_name:<26} to {raw_file}')
                total_image +=2
            elif msg.encoding == 'mono8':
                cv_image = self.bridge.imgmsg_to_cv2(msg, "mono8")
                cv2.imwrite(image_file, cv_image)

                raw_file = os.path.join(self.save_path, f'{topic_base_name}_{frame_id}.raw')
                np_array = np.array(cv_image, dtype=np.uint8)
                np_array.tofile(raw_file)
                print(f'Saved {len(self.saved_topics)}/{len(topics_to_subscribe)}: {topic_name:<26} to {raw_file}')
                total_image +=1
            else:
                # Convert and save color image
                cv_image = self.bridge.imgmsg_to_cv2(msg, "bgr8")
                cv2.imwrite(image_file, cv_image)
                print(f'Saved {len(self.saved_topics)}/{len(topics_to_subscribe)}: {topic_name:<26} to {image_file}')
                total_image +=1
        except CvBridgeError as e:
            print(f'Failed to convert message for topic {topic_name}: {e}')

    def save_point_cloud(self, msg, topic_name):

        points = self.pointcloud2_to_xyz(msg)

        pointcloud_file_pcd = os.path.join(self.save_path, f'{topic_name.replace("/", "_")}.pcd')
        pointcloud_file_ply = os.path.join(self.save_path, f'{topic_name.replace("/", "_")}.ply')
        print(f'Saved {len(self.saved_topics)}/{len(topics_to_subscribe)}: {topic_name:<26} to {pointcloud_file_pcd}')
        self.save_pcd_file(points, pointcloud_file_pcd)
        print(f'Saved {len(self.saved_topics)}/{len(topics_to_subscribe)}: {topic_name:<26} to {pointcloud_file_ply}')
        self.save_ply_file(points, pointcloud_file_ply)
        global total_image
        total_image +=2


    def pointcloud2_to_xyz(self, cloud_msg):
        points = []
        fmt = 'fff'  # Assuming XYZ only, adjust if more fields are needed
        point_step = cloud_msg.point_step
        for i in range(0, len(cloud_msg.data), point_step):
            x, y, z = struct.unpack_from(fmt, cloud_msg.data, offset=i)
            points.append([x, y, z])
        return np.array(points, dtype=np.float32)

    def save_pcd_file(self, points, file_path):
        with open(file_path, 'w') as f:
            f.write(f"# .PCD v0.7 - Point Cloud Data file format\n")
            f.write(f"VERSION 0.7\n")
            f.write(f"FIELDS x y z\n")
            f.write(f"SIZE 4 4 4\n")
            f.write(f"TYPE F F F\n")
            f.write(f"COUNT 1 1 1\n")
            f.write(f"WIDTH {len(points)}\n")
            f.write(f"HEIGHT 1\n")
            f.write(f"POINTS {len(points)}\n")
            f.write(f"DATA ascii\n")
            for point in points:
                f.write(f"{point[0]} {point[1]} {point[2]}\n")

    def save_ply_file(self, points, file_path):
        with open(file_path, 'w') as f:
            f.write("ply\n")
            f.write("format ascii 1.0\n")
            f.write(f"element vertex {len(points)}\n")
            f.write("property float x\n")
            f.write("property float y\n")
            f.write("property float z\n")
            f.write("end_header\n")
            for point in points:
                f.write(f"{point[0]} {point[1]} {point[2]}\n")

    def check_timeout(self):
        current_time = self.get_clock().now()
        elapsed_time = (current_time - self.start_time).nanoseconds / 1e9  # Convert to seconds
        if elapsed_time > 5:
            if elapsed_time > 10:
                print('Timeout reached, exit')
                safe_exit(0,"timeout")
            else:
                print('Waiting for topic messages...')

def search_topics(node):
    topics = node.get_topic_names_and_types()
    if not topics:
        print("No topics found.")
        return []

    formatted_topics = []
    for topic_name, topic_types in topics:
        for topic_type in topic_types:
            try:
                formatted_topics.append((topic_name, topic_type))
                # print(f"Found topic: {topic_name}, Type: {topic_type}")
            except Exception as e:
                print(f"Failed to import topic type {topic_type}: {e}")
                continue

    return formatted_topics

def filter_topics_include(topics):
    topics_monitor_search = []
    for topic_name, topic_type_str in topics:
        if "sensor_msgs/msg/Image" in topic_type_str or "sensor_msgs/msg/PointCloud2" in topic_type_str:
            topics_monitor_search.append((topic_name, topic_type_str))
    return topics_monitor_search

def filter_topics_exclude(topics):
    excluded_types = [
        "rcl_interfaces/msg/Log",
        "sensor_msgs/msg/CameraInfo",
        "sensor_msgs/msg/CompressedImage",
        "orbbec_camera_msgs/msg/Metadata",
        "theora_image_transport/msg/Packet"
    ]

    topics_monitor_search = []
    for topic_name, topic_type_str in topics:
        if topic_type_str not in excluded_types:
            topics_monitor_search.append((topic_name, topic_type_str))

    return topics_monitor_search

def filter_topics_exclude_log(topics):
    excluded_types = ["rcl_interfaces/msg/Log"]
    topics_monitor_search = []
    for topic_name, topic_type_str in topics:
        if topic_type_str not in excluded_types:
            topics_monitor_search.append((topic_name, topic_type_str))

    return topics_monitor_search

def check_update_list(topics):
    for topic_name, topic_type_str in topics:
        if topic_name not in topics_test_result:
            topics_test_result[topic_name] = {
                "topic_name": topic_name,
                "topic_type": topic_type_str,
                "has_publisher": 1,
                "average_interval_ms": 0,
                "data_content":  [0] * 16,
                "status": "checking",
                "last_time": 0,
                "timestamp": 0,
                "last_timestamp": 0,
                "diff_timestamp": 0,
                "curr_diff_timestamp": 0,
                "frame_id_cnt": 0,
                "frame_drop_count": 0,
                "height": 0,
                "width": 0
            }


def help_menu():
    print(f"\nhelp menu:")
    print(f"auto (or no param)     --- auto search topic and monitor")
    print(f"config or cfg          --- use default config topics_monitor list")
    print(f"all                    --- all topics excluding /log")
    print(f"search or s            --- search all topics and list")
    print(f"-h or --help           --- menu")


class SHELL_DATA:
    def __init__(self):
        self.srcStrBuf = ""  # Original command string
        self.srcStrCmd = ""  # First command
        self.srcStrArg = ""  # Arguments
        self.argvBuf = ""    # Argument buffer
        self.argc = 0        # Number of arguments
        self.argv = []       # List of argument pointers

def main(args=None):


        rclpy.init(args=args)
        node = Node("topic_searcher")

        args = sys.argv[1:]
        shell_data = SHELL_DATA()
        shell_data.srcStrBuf = " ".join(sys.argv[1:])  # Original command string
        shell_data.srcStrCmd = args[0] if args else ""  # First command
        shell_data.srcStrArg = " ".join(args[1:])  # Arguments
        shell_data.argvBuf = " ".join(args)  # Argument buffer
        shell_data.argc = len(args)  # Number of arguments
        shell_data.argv = args if args else ['']

        print_debug(f"shell_data.srcStrBuf: {shell_data.srcStrBuf}")
        print_debug(f"shell_data.srcStrCmd: {shell_data.srcStrCmd}")
        print_debug(f"shell_data.srcStrArg: {shell_data.srcStrArg}")
        print_debug(f"shell_data.argc Count: {shell_data.argc}")
        print_debug(f"shell_data.argv List: {shell_data.argv}")
        global topics_to_subscribe

        if shell_data.argv[0]=="":
            shell_data.argv[0]="auto"

        match shell_data.argv[0]:
            case 'config' | 'cfg': # user config topics monitor
                print(f"user config topics monitor  :")
                topics_to_subscribe = topics_monitor
                print_topics(topics_to_subscribe)

            case 'auto' | 'filter': #auto monitor image and point cloud
                print(f"auto monitor image and point cloud:")
                search = search_topics(node)
                print_topics(search,"Search Topics:")
                topics_to_subscribe = filter_topics_include(search)  #search #
                print_topics(topics_to_subscribe,"filter topics")
                if not topics_to_subscribe:
                    print("No topics matched the filter criteria.")
                    return
                check_update_list(topics_to_subscribe)
            case 'all':  #all  topics exclude /log
                print(f"all topics exclude /log:")
                search = search_topics(node)
                print_topics(search,"Search Topics")
                topics_to_subscribe = filter_topics_exclude(search)  #search #
                print_topics(topics_to_subscribe,"filter_topics_exclude" )
                if not topics_to_subscribe:
                    print("No topics matched the filter criteria.")
                    return
                check_update_list(topics_to_subscribe)
            case 'all_much':  #all  topics exclude /log
                print(f"all topics exclude /log:")
                search = search_topics(node)
                print_topics(search,"Search Topics")
                topics_to_subscribe = filter_topics_exclude_log(search)  #search #
                print_topics(topics_to_subscribe,"filter_topics_exclude" )
                if not topics_to_subscribe:
                    print("No topics matched the filter criteria.")
                    return
                check_update_list(topics_to_subscribe)

            case 'search' | 'ser': #only search topic
                print("Searching all topics...")
                search = search_topics(node)
                print_topics(search, "Search Topics:")
                return

            case '-h' | '--help':
                help_menu()
                return

            case _:
                help_menu()
                print(f"Unknown command: {shell_data.srcStrCmd}")
                return

        topic_monitor = TopicSubscriber(topics_to_subscribe)

        executor = MultiThreadedExecutor()
        executor.add_node(topic_monitor)
        executor.spin()



if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        safe_exit(0, "Ctrl+C exit")
    except Exception as e:
        safe_exit(1, f"warning exit: {e}")
    finally:
        safe_exit(0)
