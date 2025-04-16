"""
ros2 launch <package_name>  <launch_file_name>.launch.py  -- list/search all launch files support in project`s install floder
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


#!/usr/bin/env python3



import os
import subprocess

def is_ros2_environment_sourced():
    return 'AMENT_PREFIX_PATH' in os.environ

def find_install_dir(start_path):
    for root, dirs, _ in os.walk(start_path):
        if 'install' in dirs:
            return os.path.join(root, 'install')
    return None

def list_ros2_launch_files(install_dir, output_file):
    with open(output_file, 'w') as f:
        package_dirs = sorted(os.listdir(install_dir))
        for package_dir in package_dirs:
            package_path = os.path.join(install_dir, package_dir)
            if os.path.isdir(package_path):
                package_name = os.path.basename(package_path)
                share_dir = os.path.join(package_path, 'share', package_name)
                if os.path.isdir(share_dir):
                    launch_dir = os.path.join(share_dir, 'launch')
                    if os.path.isdir(launch_dir):
                        launch_files = sorted(os.listdir(launch_dir))
                        for launch_file in launch_files:
                            if launch_file.endswith('.py'):
                                launch_file_name = os.path.basename(launch_file)
                                launch_command = f"ros2 launch {package_name} {launch_file_name}"
                                print(launch_command)
                                f.write(launch_command + '\n')
                if os.path.isdir(share_dir):
                    launch_files = sorted(os.listdir(share_dir))
                    for launch_file in launch_files:
                        if launch_file.endswith('.py'):
                            launch_file_name = os.path.basename(launch_file)
                            launch_command = f"ros2 launch {package_name} {launch_file_name}"
                            print(launch_command)
                            f.write(launch_command + '\n')

if __name__ == "__main__":
    if not is_ros2_environment_sourced():
        print("ROS 2 environment not sourced. Please source your ROS 2 setup file.")
        exit(1)

    current_dir = os.getcwd()
    install_dir = find_install_dir(current_dir)
    if not install_dir:
        print(f"Install directory not found in the current path: {current_dir}")
        exit(1)
    
    # data_dir = os.path.join(current_dir, '~/_data')
    data_dir = os.path.expanduser('~/_data')

    if not os.path.exists(data_dir):
        os.makedirs(data_dir)

    output_file = os.path.join(data_dir, '.launch_list.txt')
    list_ros2_launch_files(install_dir, output_file)
    print(f"Launch commands have been saved to {output_file}")