"""
record all msg, default record 10s,  support config record time.  eg. rosbag2_auto.py 100   --- record 100s
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
import subprocess
import argparse
import os
import sys
import time
import traceback
from rclpy.node import Node
from datetime import datetime, timedelta
import builtins  # 导入原生 self.get_logger().info 函数

OUTPUT_FILE_PATH = "~/_data/rosbag"

# ros2命令.参考
# 录制所有话题	ros2 bag record -a
# 录制特定话题	ros2 bag record -o my_bag /topic1 /topic2
# 排除某些话题	ros2 bag record -a --exclude /tf /tf_static
# 停止录制	Ctrl + C
# 播放 bag 文件	ros2 bag play my_bag
# 加速播放	ros2 bag play my_bag --rate 2.0
# 循环播放	ros2 bag play my_bag --loop
# 播放特定话题	ros2 bag play my_bag --topics /topic1
# 查看 bag 文件信息	ros2 bag info my_bag
#  ros2 bag play vl_ros2_bag/ -- start-offset 30 --duration 10
#  --start-offset 30   从第30秒开始播放
#  --duration 10  播放10秒停止

class BagRecorder(Node):
    def __init__(self, record_duration):
        super().__init__('bag_recorder')
        self.record_duration = record_duration
        self.save_path = self.create_save_directory()
        self.start_time = datetime.now()
        self.is_recording = True
        self.start_recording()
        self.progress_timer = self.create_timer(1.0, self.print_progress)
        self.stop_timer = self.create_timer(self.record_duration, self.stop_recording)

    def create_save_directory(self):
        out_path = os.path.expanduser(OUTPUT_FILE_PATH)
        os.makedirs(out_path, exist_ok=True)
        self.get_logger().info(f"Output path: {out_path}")
        timestamp = datetime.now().strftime("%d%H_%M%S")
        save_path = out_path #os.path.join(out_path, f'image_{timestamp}')
        os.makedirs(save_path, exist_ok=True)
        return save_path

    def start_recording(self):
        start_time_str = self.start_time.strftime("%d%H%M%S")
        end_time = self.start_time + timedelta(seconds=self.record_duration)
        end_time_str = end_time.strftime("%d%H%M%S")
        bag_file_name = f"rosbag2_start_{start_time_str}_{end_time_str}_{self.record_duration}s"
        bag_file_path = os.path.join(self.save_path, bag_file_name)
        self.bag_file_path = bag_file_path
        self.bag_file_name = bag_file_name

        self.get_logger().info(f"Starting recording for {self.record_duration} seconds to {bag_file_path}...")
        self.recording_process = subprocess.Popen(['ros2', 'bag', 'record', '-a', '-o', bag_file_path])

    def print_progress(self):
        current_time = datetime.now()
        elapsed_time = (current_time - self.start_time).total_seconds()
        progress = (elapsed_time / self.record_duration) * 100
        self.get_logger().info(f"Recording progress: {progress:.0f}% .   {elapsed_time:.0f}s / total time {self.record_duration}s")

    def stop_recording(self):
        if not self.is_recording:
            return  # Prevent multiple calls to stop_recording

        self.is_recording = False
        self.get_logger().info("stop_recording")
        self.recording_process.terminate()
        try:
            self.recording_process.wait(timeout=10)  # Wait for the process to terminate
        except subprocess.TimeoutExpired:
            self.get_logger().info("Recording process did not terminate. Killing it...")
            self.recording_process.kill()  # Force kill if it doesn't terminate
        except Exception as e:
            self.get_logger().error(f"Error while waiting for the recording process: {e}")
        # Cancel timers
        if self.progress_timer:
            self.progress_timer.cancel()  # Cancel the progress timer
        if self.stop_timer:
            self.stop_timer.cancel()  # Cancel the stop timer
        self.get_logger().info("")
        self.get_logger().info(f"Record total: {self.record_duration}s")
        self.get_logger().info(f"Save patch: {self.save_path}")
        self.get_logger().info(f"Save file patch: {self.bag_file_path}")
        self.get_logger().info(f"Save file name: {self.bag_file_name}   ")
        time.sleep(1)
        safe_exit(0,"Record Finished")

def safe_exit(exit_code=0, message=""):
    if message != "":
        self.get_logger().info(f"{message}")
    try:
        if rclpy.ok():
            rclpy.shutdown()
    except Exception as e:
        self.get_logger().info(f"exit warning: {e}")
        traceback.self.get_logger().info_exc()
    finally:
        sys.exit(exit_code)

def main(args=None):
    parser = argparse.ArgumentParser(description="Record ROS 2 topics and save to a bag file.")
    parser.add_argument('duration', type=int, nargs='?', default=10, help="Recording duration in seconds (default: 10 seconds)")

    args = parser.parse_args()

    rclpy.init(args=sys.argv)
    bag_recorder = BagRecorder(args.duration)

    try:
        rclpy.spin(bag_recorder)
    except KeyboardInterrupt:
        bag_recorder.get_logger().info("Recording interrupted by user.")
        bag_recorder.stop_recording()  # Ensure stopping the recording
    finally:
        rclpy.shutdown()  # Shutdown the ROS 2 context

if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        safe_exit(0, "Ctrl+C exit")
    except Exception as e:
        safe_exit(1, f"warning exit: {e}")
    finally:
        safe_exit(0)