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
from rclpy.executors import MultiThreadedExecutor
from sensor_msgs.msg import Image, PointCloud2
from cv_bridge import CvBridge, CvBridgeError
import cv2
import os
import numpy as np
import datetime
import atexit
import struct
import subprocess
import argparse
import time
import sys

class ImageSaver(Node):
    def __init__(self, record_duration):
        super().__init__('image_saver')
        self.bridge = CvBridge()
        self.save_path = self.create_save_directory()
        self.topics_to_subscribe = [
            ("/cam0/color/image_raw", Image),
            ("/cam1/color/image_raw", Image),
            ("/cam2/color/image_raw", Image),
            ("/cam3/color/image_raw", Image),
            ("/cam4/color/image_raw", Image),
            ("/cam0/depth/image_raw", Image),
            ("/cam1/depth/image_raw", Image),
            ("/cam2/depth/image_raw", Image),
            ("/cam3/depth/image_raw", Image),
            ("/cam4/depth/image_raw", Image),
            ("/cam0/left_ir/image_raw", Image),
            ("/cam1/left_ir/image_raw", Image),
            ("/cam2/left_ir/image_raw", Image),
            ("/cam3/left_ir/image_raw", Image),
            ("/cam4/left_ir/image_raw", Image),
            # ("/cam0/depth/points", PointCloud2),
            # ("/cam1/depth/points", PointCloud2),
            # ("/cam2/depth/points", PointCloud2),
            # ("/cam3/depth/points", PointCloud2),
            # ("/cam4/depth/points", PointCloud2),
            ("/cam0_pcl", PointCloud2),
            ("/cam1_pcl", PointCloud2),
            ("/cam2_pcl", PointCloud2),
            ("/cam3_pcl", PointCloud2),
            ("/cam4_pcl", PointCloud2),
        ]
        self.saved_topics = set()
        self.topic_subscriptions = {}
        self.record_duration = record_duration
        self.start_time = self.get_clock().now()
        self.timeout_timer = self.create_timer(1.0, self.check_timeout)

        # Start recording all topics
        self.start_recording()

        for topic, msg_type in self.topics_to_subscribe:
            self.topic_subscriptions[topic] = self.create_subscription(
                msg_type,
                topic,
                lambda msg, topic=topic: self.image_callback(msg, topic),
                10
            )

    def create_save_directory(self):
        # Create the 'out' folder if it does not exist
        out_path = os.path.join(os.getcwd(), 'save')
        os.makedirs(out_path, exist_ok=True)

        # Create the timestamped save directory within the 'out' folder
        timestamp = datetime.datetime.now().strftime("%d%H_%M%S")
        save_path = os.path.join(out_path, f'image_{timestamp}')
        os.makedirs(save_path, exist_ok=True)
        return save_path

    def image_callback(self, msg, topic):
        if topic not in self.saved_topics:
            if isinstance(msg, Image):
                self.save_image(msg, topic)
            elif isinstance(msg, PointCloud2):
                self.save_point_cloud(msg, topic)
            self.saved_topics.add(topic)
            if len(self.saved_topics) == len(self.topics_to_subscribe):
                self.get_logger().info('All images saved, shutting down.')
                rclpy.shutdown()  # Initiate shutdown
                self.destroy_node()  # Destroy the node

    def save_image(self, msg, topic_name):
        frame_id = msg.header.frame_id
        topic_base_name = topic_name.replace("/", "_")
        image_file = os.path.join(self.save_path, f'{topic_base_name}_{frame_id}.jpg')

        try:
            if msg.encoding in ['16UC1', '32FC1']:
                # Convert and save depth image
                cv_image = self.bridge.imgmsg_to_cv2(msg, desired_encoding="passthrough")
                image_file = image_file.replace('.jpg', '.png')  # Use PNG for depth images
                cv2.imwrite(image_file, cv_image)

                # Save raw depth data
                raw_file = os.path.join(self.save_path, f'{topic_base_name}_{frame_id}.raw')
                np_array = np.array(cv_image, dtype=np.uint16 if msg.encoding == '16UC1' else np.float32)
                np_array.tofile(raw_file)
                self.get_logger().info(f'Saved {topic_name} to {raw_file}')
            elif msg.encoding == 'mono8':
                cv_image = self.bridge.imgmsg_to_cv2(msg, "mono8")
                cv2.imwrite(image_file, cv_image)

                raw_file = os.path.join(self.save_path, f'{topic_base_name}_{frame_id}.raw')
                np_array = np.array(cv_image, dtype=np.uint8)
                np_array.tofile(raw_file)
                self.get_logger().info(f'Saved {topic_name} to {raw_file}')
            else:
                # Convert and save color image
                cv_image = self.bridge.imgmsg_to_cv2(msg, "bgr8")
                cv2.imwrite(image_file, cv_image)
                self.get_logger().info(f'Saved {topic_name} to {image_file}')
        except CvBridgeError as e:
            self.get_logger().error(f'Failed to convert message for topic {topic_name}: {e}')

    def save_point_cloud(self, msg, topic_name):
        points = self.pointcloud2_to_xyz(msg)
        pointcloud_file_pcd = os.path.join(self.save_path, f'{topic_name.replace("/", "_")}.pcd')
        pointcloud_file_ply = os.path.join(self.save_path, f'{topic_name.replace("/", "_")}.ply')
        self.save_pcd_file(points, pointcloud_file_pcd)
        self.save_ply_file(points, pointcloud_file_ply)
        self.get_logger().info(f'Saved pointcloud from {topic_name} to {pointcloud_file_pcd} and {pointcloud_file_ply}')

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

    def start_recording(self):
        self.get_logger().info(f"Starting recording for {self.record_duration} seconds...")
        self.recording_process = subprocess.Popen(['ros2', 'bag', 'record', '-a'])
        self.recording_start_time = time.time()
    def check_timeout(self):
        current_time = self.get_clock().now()
        elapsed_time = (current_time - self.start_time).nanoseconds / 1e9  # Convert to seconds
        recording_elapsed_time = time.time() - self.recording_start_time

        if elapsed_time > 7:
            if elapsed_time > 15:
                self.get_logger().info('Timeout reached. Shutting down.')
                rclpy.shutdown()
                self.destroy_node()
            else:
                self.get_logger().info('Waiting for topic messages...')

        if recording_elapsed_time >= self.record_duration:
            self.get_logger().info(f"Recording completed after {recording_elapsed_time:.2f} seconds.")
            self.recording_process.terminate()
            self.recording_process.wait()
            rclpy.shutdown()
            self.destroy_node()

def main(args=None):
    parser = argparse.ArgumentParser(description="Record ROS 2 topics and save images.")
    parser.add_argument('--duration', type=int, default=5, help="Recording duration in seconds (default: 5 seconds)")
    args = parser.parse_args()

    rclpy.init(args=sys.argv)
    image_saver = ImageSaver(args.duration)
    executor = MultiThreadedExecutor()

    def shutdown_handler():
        if rclpy.ok():
            rclpy.shutdown()

    atexit.register(shutdown_handler)

    try:
        executor.add_node(image_saver)
        executor.spin()
    except KeyboardInterrupt:
        pass
    finally:
        executor.shutdown()
        os._exit(0)  # Ensure the program exits immediately

if __name__ == '__main__':
    main()
