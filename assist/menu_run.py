"""
ros2 run <package_name> <executable_name>  ---  list/search all run/executables files support in project`s install floder
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

def list_ros2_packages(install_dir, output_file):
    with open(output_file, 'w') as f:
        # 获取所有包目录并按字母顺序排序
        package_dirs = sorted(os.listdir(install_dir))
        for package_dir in package_dirs:
            package_path = os.path.join(install_dir, package_dir)
            if os.path.isdir(package_path):
                package_name = os.path.basename(package_path)
                executables_dir = os.path.join(package_path, 'lib', package_name)
                if os.path.isdir(executables_dir):
                    # 获取所有可执行文件并按字母顺序排序
                    executables = sorted(os.listdir(executables_dir))
                    for executable in executables:
                        executable_path = os.path.join(executables_dir, executable)
                        if os.access(executable_path, os.X_OK):
                            run_command = f"ros2 run {package_name} {executable}"
                            print(run_command)
                            f.write(run_command + '\n')

if __name__ == "__main__":
    if not is_ros2_environment_sourced():
        print("ROS 2 environment not sourced. Please source your ROS 2 setup file.")
        exit(1)

    current_dir = os.getcwd()
    install_dir = find_install_dir(current_dir)
    if not install_dir:
        print(f"Install directory not found in the current path: {current_dir}")
        exit(1)


    # data_dir = os.path.join(current_dir, '_data')
    data_dir = os.path.expanduser('~/_data')
    if not os.path.exists(data_dir):
        os.makedirs(data_dir)

    output_file = os.path.join(data_dir, '.menu_run.txt')
    list_ros2_packages(install_dir, output_file)
    print(f"Run commands have been saved to {output_file}")