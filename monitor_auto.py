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
import time
import struct
import argparse
import datetime
import sys
import subprocess
import re
from rclpy.node import Node
from rclpy.executors import MultiThreadedExecutor
from tf2_ros import Buffer, TransformListener
from geometry_msgs.msg import TransformStamped
from rosidl_runtime_py.utilities import get_message
from sensor_msgs.msg import Image, PointCloud2
from functools import partial
#######################################################
#在这里设置默认监控的话题, 其它地方不需要修改. 执行脚本默认会自动搜索topic , 当输入config 参数, 脚本会监控该列表话题



topics_monitor = [
    ("/camera/depth/image_raw", "sensor_msgs/msg/Image"),
    ("/camera/color/image_raw", "sensor_msgs/msg/Image"),
    ("/camera/depth/points", "sensor_msgs/msg/PointCloud2"),
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

topics_test_result = {}

debug_enable = 0  #debug switch
print_enabled = False
last_toggle_time = time.time()


#######################################################
def calculate_sliding_average(current_interval, last_average):
    if last_average == 0:
        return current_interval
    return last_average + (current_interval - last_average) / 16

def calculate_sliding_average(current_interval, last_average, param=16):
    if last_average == 0:
        return current_interval
    return last_average + (current_interval - last_average) / param


def print_topic_data(topic_data, tital=""):
    tmp = topic_data['topic_type']
    topic_type = tmp.split('/')[-1]
    print(
        f"{topic_data['topic_name']:<26} {topic_type:<12}: "
        f"pub {topic_data['has_publisher']},"
        f"{(1.0 / topic_data['average_interval_ms'] if topic_data['average_interval_ms'] != 0 else 0):.0f}hz,"
        f"{topic_data['average_interval_ms'] * 1000:.0f}ms,"
        f"{topic_data['timestamp']:.3f},"
        f"{topic_data['curr_diff_timestamp']* 1000:.0f}ms,"
        f"{topic_data['status']}, "
        f"{topic_data['width']}*{topic_data['height']}, "
        f"total/drop/img-/stream-:"
        f"{topic_data['frame_id_cnt']:<3}/"
        f"{topic_data['frame_drop_count']}/"
        f"{topic_data['depth_error_count']}/"
        f"{topic_data['stream_error_count']}, "
        f"data{topic_data['data_content'][:4]}"
    )

def callback_default(msg, topic_name, topic_type_str):
    current_time = time.time()
    topic_data = topics_test_result[topic_name]

    if topic_data['last_time'] > 0:
        current_interval = current_time - topic_data['last_time']
        new_average = calculate_sliding_average(current_interval, topic_data['average_interval_ms'])

        topic_data['average_interval_ms'] = new_average
        topic_data['has_publisher'] = 1
        topic_data['status'] = "checking"
        topic_data['height'] = 0
        topic_data['width'] = 0
        topic_data['timestamp'] = 0
        topic_data['data_content'] = [0] * 16

        topic_data['frame_id_cnt'] += 1

        topic_data['timestamp'] = msg.header.stamp.sec + msg.header.stamp.nanosec * 1e-9
        topic_data['curr_diff_timestamp']= topic_data['timestamp']- topic_data['last_timestamp']

        timestamp_error = 0

        if  topic_data['frame_id_cnt'] > 10:
            if not (topic_data['diff_timestamp'] * 0.5 <= topic_data['curr_diff_timestamp'] <= topic_data['diff_timestamp'] * 1.5):
                timestamp_error = 1
                topic_data['frame_drop_count'] += 1
        else:
            topic_data['diff_timestamp'] = calculate_sliding_average(topic_data['curr_diff_timestamp'], topic_data['diff_timestamp'])

        if isinstance(msg, Image) or isinstance(msg, PointCloud2):
            topic_data['height'] = msg.height
            topic_data['width'] = msg.width

            width = msg.width
            height = msg.height
            center_index = (height // 2) * width + (width // 2)

            if isinstance(msg, Image) and msg.encoding == 'mono8':
                bytes_per_pixel = 1
            else:
                bytes_per_pixel = 2

            center_byte_index = center_index * bytes_per_pixel

            data_length = len(msg.data)
            if center_byte_index + 32 <= data_length:
                data_content = msg.data[center_byte_index: center_byte_index + 32]
                topic_data['data_content'] = list(struct.unpack('<' + 'H' * 16, data_content))
            else:
                print(f"Warning: {topic_name} data index out of range ({center_byte_index + 32} > {data_length})")


            if timestamp_error == 1:
                topic_data['status']  = "warning"
                # print_topic_data(topic_data)
                print_debug(f"warning frame_drop:"
                      f"current timestamp= {topic_data['timestamp']:.3f}, "
                      f"last timestamp= {topic_data['last_timestamp']:.3f}, "
                      f"diff {topic_data['curr_diff_timestamp']:.3f}, {topic_data['diff_timestamp']:.3f}")

        if print_enabled and not timestamp_error:
            print_topic_data(topic_data)


    else:
        topic_data['average_interval_ms'] = 0
        topic_data['has_publisher'] = 1
        topic_data['status'] = "Initial"
        topic_data['data_content'] = [0] * 16
        topic_data['diff_timestamp'] = 0
        topic_data['timestamp'] = msg.header.stamp.sec + msg.header.stamp.nanosec * 1e-9
        topic_data['frame_drop_count'] = 0

    topic_data['last_time'] = current_time
    topic_data['last_timestamp'] = topic_data['timestamp']

def print_debug(*args, **kwargs):
    global debug_enable
    debug_enable = int(debug_enable)
    if debug_enable != 1:
        return
    timestamp = datetime.datetime.now().strftime("[%m %H:%M:%S.%f")[:-3]+ "]"
    print(timestamp, *args, **kwargs)

class TopicSubscriber(Node):
    def __init__(self, topics_to_subscribe):
        super().__init__("topic_subscriber")
        self.logger = self.get_logger()
        self.subscribe_topics(topics_to_subscribe)
        self.print_timer = self.create_timer(0.5, self.toggle_print)

    def subscribe_topics(self, topics_to_subscribe):
        for topic_name, topic_type_str in topics_to_subscribe:
            # 动态导入消息类型
            topic_class = get_message(topic_type_str)
            self.create_subscription(
                topic_class ,
                topic_name,
                #lambda msg, tn=topic_name, tt=topic_type.__name__: callback(msg, tn, tt),
				partial(callback_default, topic_name=topic_name, topic_type_str=topic_type_str),
                10  # QoS
            )
            print(f"Subscribed topic: {topic_name:<28} {topic_type_str}")
        print(f"--------------------------------------------------------------")

    def toggle_print(self):
        global print_enabled
        global last_toggle_time
        current_time = time.time()
        #print(f"toggle_print:{current_time }, {last_toggle_time }, {current_time - last_toggle_time}, {print_enabled}")
        if print_enabled and current_time - last_toggle_time >= 0.5:
            print_enabled = False
            last_toggle_time = current_time
        elif not print_enabled and current_time - last_toggle_time >= 300:
            print_enabled = True
            last_toggle_time = current_time

    def check_topic_publishers(self):
        time.sleep(1)
        while rclpy.ok():
            current_time = time.time()
            has_fail = False

            print(f"\nTest Result:                      current system timestamp:  {current_time:.3f}")

            for topic_name, topic_data in topics_test_result.items():
                if topic_data['topic_type'] in ["sensor_msgs/msg/Image", "sensor_msgs/msg/PointCloud2"]:
                    if current_time - topic_data['last_time'] > 3:
                        topic_data['has_publisher'] = 0
                        topic_data['status'] = "fail"
                        topic_data['stream_error_count'] += 1
                    else:
                        topic_data['has_publisher'] = 1
                        topic_data['status'] = "pass"

                    # 图像识别异常
                    data_content = topic_data['data_content']
                    if data_content and isinstance(data_content, list):
                        avg_value = sum(data_content) / len(data_content)

                        if topic_data['topic_name'].endswith("depth/image_raw")  and (avg_value < 50 or avg_value > 5000):
                            topic_data['status'] = "fail"
                            topic_data['depth_error_count'] += 1

                        if current_time - topic_data['timestamp'] > 1:  #  秒
                            topic_data['status'] = "fail"
                        # diff =current_time - topic_data['timestamp']
                        # print(f"diff {diff}")

                    if topic_data['status'] == "fail":
                        has_fail = True


                if topic_data['has_publisher'] == 0:
                    topic_data['average_interval_ms'] = 0
                    topic_data['data_content'] = [0] * 16
                    topic_data['timestamp'] = 0

                print_topic_data(topic_data)

            process_cpu_usage()
            print("---------------------------------------------------------------------------------------------------------------------------------------\n")

            # 如果有失败状态，生成错误标志文件
            #if has_fail:
            #    with open("/home/ytj/error_flag", "w") as f:
            #        f.write("Error detected in topic data.\n")

            time.sleep(2)



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
            if "sensor_msgs/msg/Image" in topic_type_str:
                topics_monitor_search.append((topic_name, topic_type_str))
            elif "sensor_msgs/msg/PointCloud2" in topic_type_str:
                topics_monitor_search.append((topic_name, topic_type_str))
    return topics_monitor_search

def filter_topics_exclude(topics):
    excluded_types = ["rcl_interfaces/msg/Log",
                      "sensor_msgs/msg/CameraInfo",
                      "sensor_msgs/msg/CompressedImage",
                      "orbbec_camera_msgs/msg/Metadata",
                      "theora_image_transport/msg/Packet",

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
                "depth_error_count": 0,
                "stream_error_count": 0,
                "height": 0,
                "width": 0
            }



def print_topics(topics, title="Topics:"):
    print(f"{title}")
    for topic_name, topic_type_str in topics:
        #print(f"Topic: {topic_name}, Type: {topic_class.__name__}")
        print(f"(\"{topic_name}\", \"{topic_type_str}\"), ")
    print(f"total: {len(topics)}")

process_cpu_usage_data = {}
MAX_HISTORY = 1000

def process_cpu_usage():
    try:
        # 获取 top 输出，减少采样时间
        top_output = subprocess.check_output(['top', '-b', '-n', '1', '-d', '0.1'], universal_newlines=True)

        # 只保留匹配的进程行，提高效率
        filtered_lines = [line for line in top_output.split('\n') if 'component_conta' in line or 'nodelet' in line or 'ob_benchmark' in line]

        for line in filtered_lines:
            fields = line.strip().split()
            if len(fields) < 12:
                continue  # 跳过无效行

            pid = fields[0]
            cpu_usage = float(fields[8])  # 获取 CPU 使用率列
            command = fields[11]

            # 记录 CPU 使用率
            if pid not in process_cpu_usage_data:
                process_cpu_usage_data[pid] = {'name': command, 'cpu_usage': []}

            process_cpu_usage_data[pid]['cpu_usage'].append(cpu_usage)

            # 限制历史数据，避免过长影响计算
            if len(process_cpu_usage_data[pid]['cpu_usage']) > MAX_HISTORY:
                process_cpu_usage_data[pid]['cpu_usage'].pop(0)

        # 打印 CPU 统计信息
        for pid, data in process_cpu_usage_data.items():
            cpu_usages = data['cpu_usage']

            if not cpu_usages:
                continue  # 防止空列表

            min_cpu = min([x for x in cpu_usages if x > 0]) if any(x > 0 for x in cpu_usages) else 0  # 过滤 0 值
            max_cpu = max(cpu_usages)
            avg_cpu = sum(cpu_usages) / len(cpu_usages)
            print(f"CPU Test: pid {pid}, name {data['name']}    -----      : "
                f"CPU Usage Avg = {avg_cpu:.0f}% "
                f"(Min {min_cpu:.0f}%, "
                f"Max {max_cpu:.0f}%)")

    except Exception as e:
        print(f"CPU Test warning: {e}")

def process_cpu_usage_old():
    global process_cpu_usage_data
    top_output = subprocess.check_output(['top', '-b', '-n', '1'], universal_newlines=True)
    filtered_lines = [line for line in top_output.split('\n') if re.search(r'component_conta|nodelet|ob_benchmark', line)]

    active_pids = set()

    for line in filtered_lines:
        fields = line.split()
        if len(fields) < 12:
            continue  # Skip lines that don't have enough data

        pid = fields[0]
        cpu_usage = float(fields[8])  # %CPU column in top output
        command = fields[11]
        active_pids.add(pid)

        if pid not in process_cpu_usage_data:
            process_cpu_usage_data[pid] = {
                'name': command,
                'cpu_usage': []
            }

        process_cpu_usage_data[pid]['cpu_usage'].append(cpu_usage)

    # 移除已经结束的进程
    finished_pids = [pid for pid in process_cpu_usage_data if pid not in active_pids]
    for pid in finished_pids:
        del process_cpu_usage_data[pid]

    # Print and log the results
    for pid, data in process_cpu_usage_data.items():
        cpu_usages = data['cpu_usage']
        min_cpu = min(cpu_usages)  if any(cpu_usages) else 0
        max_cpu = max(cpu_usages)
        avg_cpu = sum(cpu_usages) / len(cpu_usages)

        print(f"\nCPU Test: pid {pid}, name {data['name']}    -----      : "
              f"CPU Usage Avg = {avg_cpu:.0f}% "
              f"(Min {min_cpu:.0f}%, "
              f"Max {max_cpu:.0f}%)")


def help_menu():
    print(f"\nhelp menu:")
    print(f"auto (or no param)     --- auto search topic and monitor ")
    print(f"config or cfg        --- use default config topics_monitor list\n")
    print(f"all           --- all  topics exclude /log\n")
    print(f"search or s     --- search all topics and list")
    print(f"-h or --help     --- menu")

class SHELL_DATA:
    def __init__(self):
        self.srcStrBuf = ""  # 原始命令字符串
        self.srcStrCmd = ""  # 第一个命令
        self.srcStrArg = ""  # 后面参数
        self.argvBuf = ""    # 存储分割的参数字符串
        self.argc = 0        # 参数个数
        self.argv = []       # 存储每个参数的指针列表

def main(args=None):

    args = sys.argv[1:]
    shell_data = SHELL_DATA()
    shell_data.srcStrBuf = " ".join(sys.argv[1:])  # 原始命令字符串
    shell_data.srcStrCmd = args[0] if args else ""  # 第一个命令
    shell_data.srcStrArg = " ".join(args[1:])  # 后面参数
    shell_data.argvBuf = " ".join(args)  # 存储分割的参数字符串
    shell_data.argc = len(args)  # 参数个数
    shell_data.argv = args if args else ['']


    print_debug(f"shell_data.srcStrBuf: {shell_data.srcStrBuf}")
    print_debug(f"shell_data.srcStrCmd: {shell_data.srcStrCmd}")
    print_debug(f"shell_data.srcStrArg: {shell_data.srcStrArg}")
    print_debug(f"shell_data.argc Count: {shell_data.argc}")
    print_debug(f"shell_data.argv List: {shell_data.argv}")

    rclpy.init(args=args)
    node = Node("topic_searcher")

    if shell_data.argv[0]=="":
        shell_data.argv[0]="auto"

    match shell_data.argv[0]:
        case 'config' | 'cfg': # user config topics monitor
            print(f"user config topics monitor  :")
            topics_to_subscribe = topics_monitor
            print_topics(topics_to_subscribe)
            check_update_list(topics_to_subscribe)
        case 'auto' | 'filter' | '' : #auto monitor image and point cloud
            print(f"auto monitor image and point cloud:")
            search = search_topics(node)
            print_topics(search,"Search Topics Results:")
            topics_to_subscribe = filter_topics_include(search)  #search #
            print_topics(topics_to_subscribe)
            if not topics_to_subscribe:
                print("No topics matched the filter criteria.")
                return
            check_update_list(topics_to_subscribe)
        case 'all':  #all  topics exclude /log
            print(f"all topics exclude /log:")
            search = search_topics(node)
            print_topics(search,"Search Topics Results")
            topics_to_subscribe = filter_topics_exclude(search)  #search #
            print_topics(topics_to_subscribe,"filter_topics_exclude" )
            if not topics_to_subscribe:
                print("No topics matched the filter criteria.")
                return
            check_update_list(topics_to_subscribe)
        case 'all_much':  #all  topics exclude /log
            print(f"all topics exclude /log:")
            search = search_topics(node)
            print_topics(search,"Search Topics Results")
            topics_to_subscribe = filter_topics_exclude_log(search)  #search #
            print_topics(topics_to_subscribe,"filter_topics_exclude" )
            if not topics_to_subscribe:
                print("No topics matched the filter criteria.")
                return
            check_update_list(topics_to_subscribe)

        case 'search' | 'ser': #only search topic
            print("Searching all topics...")
            search = search_topics(node)
            print_topics(search, "Search Topics Results:")
            return

        case '-h' | '--help':
            help_menu()
            return

        case _:
            help_menu()
            print("Please enter a correct command.")
            return

    topic_monitor = TopicSubscriber(topics_to_subscribe)
    check_thread = threading.Thread(target=topic_monitor.check_topic_publishers, daemon=True)
    check_thread.start()

    executor = MultiThreadedExecutor()
    rclpy.spin(topic_monitor, executor=executor)

    topic_monitor.destroy_node()
    if rclpy.ok():
        rclpy.shutdown()

if __name__ == "__main__":
    main()
